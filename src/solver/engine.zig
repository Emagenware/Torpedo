const std = @import("std");
const board_mod = @import("../board.zig");
const rules = @import("rules.zig");
const csp = @import("csp.zig");
const Board = board_mod.Board;
const Coord = board_mod.Coord;

pub const ThinkLevel = enum {
    basic, // single-constraint saturation only
    subset, // + generalized subset elimination (1-2-1 style patterns)
    exact, // + exact combinatorial CSP with global mine-count coupling

    pub fn label(self: ThinkLevel) []const u8 {
        return switch (self) {
            .basic => "basic",
            .subset => "subset",
            .exact => "exact",
        };
    }

    pub fn parse(s: []const u8) ?ThinkLevel {
        if (std.mem.eql(u8, s, "basic")) return .basic;
        if (std.mem.eql(u8, s, "subset")) return .subset;
        if (std.mem.eql(u8, s, "exact")) return .exact;
        return null;
    }
};

pub const Profile = struct {
    think: ThinkLevel,
    blunder_chance: f64,
    label: []const u8,
};

/// Maps an Elo-style rating onto a thinking depth and a chance of making an
/// outright mistake (clicking a cell that is known or likely to be a mine),
/// mirroring how chess engines simulate weaker opponents.
pub fn profileForElo(elo: f64) Profile {
    if (elo < 400) return .{ .think = .basic, .blunder_chance = 0.40, .label = "Beginner" };
    if (elo < 800) return .{ .think = .basic, .blunder_chance = 0.22, .label = "Casual" };
    if (elo < 1200) return .{ .think = .subset, .blunder_chance = 0.12, .label = "Club Player" };
    if (elo < 1600) return .{ .think = .subset, .blunder_chance = 0.05, .label = "Expert" };
    if (elo < 2000) return .{ .think = .exact, .blunder_chance = 0.02, .label = "Master" };
    if (elo < 2400) return .{ .think = .exact, .blunder_chance = 0.005, .label = "Grandmaster" };
    return .{ .think = .exact, .blunder_chance = 0.0, .label = "Torpedo (perfect play)" };
}

pub const Analysis = struct {
    arena: *std.heap.ArenaAllocator,
    certain_safe: []Coord,
    certain_mines: []Coord,
    probabilities: []f64, // size w*h, -1 where not applicable
    exact: bool,
    chosen_move: ?Coord,
    is_guess: bool,
    blundered: bool,
    move_probability: f64,
    profile: Profile,
    fully_revealed: bool,

    pub fn deinit(self: *Analysis, base_allocator: std.mem.Allocator) void {
        self.arena.deinit();
        base_allocator.destroy(self.arena);
    }
};

pub fn analyze(
    base_allocator: std.mem.Allocator,
    board: Board,
    elo: f64,
    think_override: ?ThinkLevel,
    rng: std.Random,
) !Analysis {
    const base_profile = profileForElo(elo);
    const profile: Profile = .{
        .think = think_override orelse base_profile.think,
        .blunder_chance = base_profile.blunder_chance,
        .label = base_profile.label,
    };

    const arena_ptr = try base_allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(base_allocator);
    errdefer {
        arena_ptr.deinit();
        base_allocator.destroy(arena_ptr);
    }
    const a = arena_ptr.allocator();

    var ded = try rules.Deduction.init(a, board.width * board.height);

    switch (profile.think) {
        .basic => _ = try rules.basicFixpoint(a, board, &ded),
        .subset => _ = try rules.subsetFixpoint(a, board, &ded),
        .exact => _ = try rules.basicFixpoint(a, board, &ded),
    }

    var exact = true;
    var probabilities: []f64 = undefined;

    if (profile.think == .exact) {
        const result = try csp.computeProbabilities(a, board, &ded);
        probabilities = result.probabilities;
        exact = result.exact;
        for (result.newly_safe) |ci| ded.safe[ci] = true;
        for (result.newly_mine) |ci| ded.mine[ci] = true;
    } else {
        probabilities = try estimateLocalProbabilities(a, board, &ded);
    }

    var certain_safe: std.ArrayList(Coord) = .empty;
    var certain_mines: std.ArrayList(Coord) = .empty;
    const n = board.width * board.height;
    for (0..n) |i| {
        if (board.state[i] != .hidden) continue;
        if (ded.safe[i]) try certain_safe.append(a, board.coordOf(i));
        if (ded.mine[i]) try certain_mines.append(a, board.coordOf(i));
    }

    var chosen: ?Coord = null;
    var is_guess = false;
    var move_p: f64 = 0;

    if (certain_safe.items.len > 0) {
        chosen = certain_safe.items[0];
        move_p = 0;
    } else {
        var best: ?usize = null;
        var best_p: f64 = 2.0;
        for (0..n) |i| {
            if (board.state[i] != .hidden) continue;
            if (ded.mine[i]) continue;
            const p = probabilities[i];
            const pp: f64 = if (p < 0) 0.5 else p;
            if (pp < best_p) {
                best_p = pp;
                best = i;
            }
        }
        if (best) |bi| {
            chosen = board.coordOf(bi);
            move_p = best_p;
            is_guess = true;
        }
    }

    var blundered = false;
    if (chosen != null and profile.blunder_chance > 0 and rng.float(f64) < profile.blunder_chance) {
        var pool: std.ArrayList(usize) = .empty;
        for (0..n) |i| {
            if (board.state[i] == .hidden) try pool.append(a, i);
        }
        if (pool.items.len > 0) {
            const pick = pool.items[rng.intRangeLessThan(usize, 0, pool.items.len)];
            chosen = board.coordOf(pick);
            move_p = if (probabilities[pick] < 0) 0.5 else probabilities[pick];
            is_guess = true;
            blundered = true;
        }
    }

    return .{
        .arena = arena_ptr,
        .certain_safe = try certain_safe.toOwnedSlice(a),
        .certain_mines = try certain_mines.toOwnedSlice(a),
        .probabilities = probabilities,
        .exact = exact,
        .chosen_move = chosen,
        .is_guess = is_guess,
        .blundered = blundered,
        .move_probability = move_p,
        .profile = profile,
        .fully_revealed = board.countHidden() == 0,
    };
}

/// Cheap probability estimate used at lower thinking levels: a mean-field
/// average of each cell's adjacent clues, with a background density for
/// cells no clue touches. Deliberately less accurate than the exact CSP
/// solver -- this models a human-ish player who hasn't worked out the full
/// joint probability picture.
fn estimateLocalProbabilities(a: std.mem.Allocator, board: Board, ded: *const rules.Deduction) ![]f64 {
    const n = board.width * board.height;
    const out = try a.alloc(f64, n);
    @memset(out, -1);

    const constraints = try rules.buildConstraints(a, board, ded);
    const sum = try a.alloc(f64, n);
    @memset(sum, 0);
    const count = try a.alloc(f64, n);
    @memset(count, 0);
    for (constraints) |c| {
        const local_p = std.math.clamp(@as(f64, @floatFromInt(c.remaining)) / @as(f64, @floatFromInt(c.cells.len)), 0, 1);
        for (c.cells) |ci| {
            sum[ci] += local_p;
            count[ci] += 1;
        }
    }

    var known_mine_count: usize = 0;
    for (0..n) |i| {
        if (ded.isKnownMine(board, i)) known_mine_count += 1;
    }
    var frontier_expected: f64 = 0;
    var unconstrained: usize = 0;
    for (0..n) |i| {
        if (board.state[i] != .hidden or ded.mine[i] or ded.safe[i]) continue;
        if (count[i] > 0) frontier_expected += sum[i] / count[i] else unconstrained += 1;
    }
    const mines_remaining_f: f64 = @floatFromInt(if (board.total_mines > known_mine_count) board.total_mines - known_mine_count else 0);
    const bg_p: f64 = if (unconstrained > 0)
        std.math.clamp((mines_remaining_f - frontier_expected) / @as(f64, @floatFromInt(unconstrained)), 0, 1)
    else
        0;

    for (0..n) |i| {
        if (board.state[i] != .hidden) continue;
        if (ded.mine[i]) {
            out[i] = 1.0;
        } else if (ded.safe[i]) {
            out[i] = 0.0;
        } else if (count[i] > 0) {
            out[i] = sum[i] / count[i];
        } else {
            out[i] = bg_p;
        }
    }
    return out;
}
