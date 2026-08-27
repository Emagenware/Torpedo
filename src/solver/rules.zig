const std = @import("std");
const board_mod = @import("../board.zig");
const Board = board_mod.Board;
const Coord = board_mod.Coord;

/// Overlay of cells the solver has deduced beyond what is physically flagged
/// or revealed on the board. Rebuilt fresh on every analysis pass.
pub const Deduction = struct {
    allocator: std.mem.Allocator,
    mine: []bool,
    safe: []bool,

    pub fn init(allocator: std.mem.Allocator, n: usize) !Deduction {
        const mine = try allocator.alloc(bool, n);
        @memset(mine, false);
        const safe = try allocator.alloc(bool, n);
        @memset(safe, false);
        return .{ .allocator = allocator, .mine = mine, .safe = safe };
    }

    pub fn isKnownMine(self: Deduction, board: Board, i: usize) bool {
        return board.state[i] == .flagged or self.mine[i];
    }

    pub fn isResolved(self: Deduction, board: Board, i: usize) bool {
        return board.state[i] != .hidden or self.mine[i] or self.safe[i];
    }
};

/// A single revealed cell's constraint on its unknown neighbors:
/// exactly `remaining` of `cells` are mines.
pub const Constraint = struct {
    owner: Coord,
    remaining: i32,
    cells: []usize, // linear board indices, owned by the caller's allocator
};

/// Builds one constraint per revealed numbered cell that still has unknown
/// (unresolved) neighbors. Allocates with `a` (expected to be an arena).
pub fn buildConstraints(a: std.mem.Allocator, board: Board, ded: *const Deduction) ![]Constraint {
    var list: std.ArrayList(Constraint) = .empty;
    var buf: [8]Coord = undefined;

    var y: usize = 0;
    while (y < board.height) : (y += 1) {
        var x: usize = 0;
        while (x < board.width) : (x += 1) {
            if (board.get(x, y) != .revealed) continue;
            const number = board.getNumber(x, y);
            const ns = board.neighbors(x, y, &buf);

            var known_mines: i32 = 0;
            var unknown: std.ArrayList(usize) = .empty;
            for (ns) |c| {
                const ci = board.idx(c.x, c.y);
                if (ded.isKnownMine(board, ci)) {
                    known_mines += 1;
                } else if (!ded.isResolved(board, ci)) {
                    try unknown.append(a, ci);
                }
            }
            if (unknown.items.len == 0) {
                unknown.deinit(a);
                continue;
            }
            try list.append(a, .{
                .owner = .{ .x = x, .y = y },
                .remaining = @as(i32, number) - known_mines,
                .cells = try unknown.toOwnedSlice(a),
            });
        }
    }
    return list.toOwnedSlice(a);
}

/// Single-constraint saturation rule: if a clue's remaining mine count is 0,
/// all its unknown neighbors are safe; if remaining equals the unknown
/// count, all its unknown neighbors are mines. Iterates to a fixpoint.
/// Returns true if anything new was deduced.
pub fn basicFixpoint(a: std.mem.Allocator, board: Board, ded: *Deduction) !bool {
    var any_change = false;
    while (true) {
        const constraints = try buildConstraints(a, board, ded);
        var changed = false;
        for (constraints) |c| {
            if (c.remaining == 0) {
                for (c.cells) |ci| {
                    if (!ded.safe[ci]) {
                        ded.safe[ci] = true;
                        changed = true;
                    }
                }
            } else if (c.remaining == @as(i32, @intCast(c.cells.len))) {
                for (c.cells) |ci| {
                    if (!ded.mine[ci]) {
                        ded.mine[ci] = true;
                        changed = true;
                    }
                }
            }
        }
        if (!changed) break;
        any_change = true;
    }
    return any_change;
}

/// Generalized subset elimination: for two clues A, B whose unknown-cell
/// sets satisfy A ⊆ B, the cells in B\A must account for exactly
/// remaining(B) - remaining(A) mines. When that difference is 0 or equals
/// |B\A|, every cell in B\A is resolved. This subsumes classic patterns like
/// 1-2-1 and 1-1 without hardcoding shapes. Iterates with the basic rule to
/// a combined fixpoint. Returns true if anything new was deduced.
pub fn subsetFixpoint(a: std.mem.Allocator, board: Board, ded: *Deduction) !bool {
    var any_change = false;
    while (true) {
        var changed = try basicFixpoint(a, board, ded);

        const constraints = try buildConstraints(a, board, ded);
        for (constraints) |ca| {
            for (constraints) |cb| {
                if (ca.cells.len >= cb.cells.len) continue;
                if (!isSubset(ca.cells, cb.cells)) continue;
                const diff_count = cb.remaining - ca.remaining;
                var diff_len: usize = 0;
                for (cb.cells) |bi| {
                    if (!contains(ca.cells, bi)) diff_len += 1;
                }
                if (diff_len == 0) continue;
                if (diff_count == 0) {
                    for (cb.cells) |bi| {
                        if (contains(ca.cells, bi)) continue;
                        if (!ded.safe[bi]) {
                            ded.safe[bi] = true;
                            changed = true;
                        }
                    }
                } else if (diff_count == @as(i32, @intCast(diff_len))) {
                    for (cb.cells) |bi| {
                        if (contains(ca.cells, bi)) continue;
                        if (!ded.mine[bi]) {
                            ded.mine[bi] = true;
                            changed = true;
                        }
                    }
                }
            }
        }
        if (!changed) break;
        any_change = true;
    }
    return any_change;
}

fn contains(set: []const usize, v: usize) bool {
    for (set) |s| {
        if (s == v) return true;
    }
    return false;
}

fn isSubset(small: []const usize, big: []const usize) bool {
    for (small) |s| {
        if (!contains(big, s)) return false;
    }
    return true;
}

test "basic fixpoint marks safe and mine cells" {
    const text =
        \\3 1 1
        \\1 ? ?
    ;
    var board = try Board.parse(std.testing.allocator, text);
    defer board.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ded = try Deduction.init(a, board.width * board.height);
    _ = try basicFixpoint(a, board, &ded);
    // (0,0)=1 has exactly one unknown neighbor, (1,0) -- remaining equals
    // the unknown count, so it must be a mine.
    try std.testing.expect(ded.mine[board.idx(1, 0)]);
}
