const std = @import("std");
const board_mod = @import("../board.zig");
const rules = @import("rules.zig");
const Board = board_mod.Board;
const Deduction = rules.Deduction;

const NEG_INF = -std.math.inf(f64);
// Real minesweeper frontiers stay small because the grid is planar, so
// backtracking with constraint pruning resolves them in milliseconds. This
// budget only exists to bound the pathological case (e.g. a hand-crafted
// board with one enormous connected frontier) so a single component can
// never hang the process; see the mean-field fallback below.
const NODE_BUDGET: u64 = 3_000_000;

fn isNegInf(v: f64) bool {
    return std.math.isInf(v) and v < 0;
}

pub const ProbabilityResult = struct {
    /// Size width*height. -1 for cells that are already revealed. For hidden
    /// cells, the estimated mine probability in [0, 1].
    probabilities: []f64,
    /// True if the result comes from exact combinatorial enumeration
    /// (globally consistent with the total mine count); false if a
    /// pathologically large frontier forced a mean-field approximation.
    exact: bool,
    /// Newly-certain cells discovered by CSP that basic/subset rules missed.
    newly_safe: []usize,
    newly_mine: []usize,
};

fn find(parent: []usize, x: usize) usize {
    var root = x;
    while (parent[root] != root) root = parent[root];
    var cur = x;
    while (parent[cur] != root) {
        const next = parent[cur];
        parent[cur] = root;
        cur = next;
    }
    return root;
}

fn unite(parent: []usize, x: usize, y: usize) void {
    const rx = find(parent, x);
    const ry = find(parent, y);
    if (rx != ry) parent[rx] = ry;
}

const LocalConstraint = struct {
    remaining: i32,
    vars: []usize, // local indices within the owning component
};

const Component = struct {
    vars: []usize, // global var indices
    cells: []usize, // board linear index per var, same order
    constraints: []LocalConstraint,
};

const CompResult = struct {
    count_by_k: []u64, // len = vars.len + 1
    mine_count_by_k: [][]u64, // [vars.len][vars.len + 1]
    exact: bool,
};

const Dfs = struct {
    comp: *const Component,
    var_constraints: []const std.ArrayList(usize),
    assigned_mines: []i32,
    assigned_count: []i32,
    assignment: []bool,
    count_by_k: []u64,
    mine_count_by_k: [][]u64,
    node_count: u64 = 0,
    aborted: bool = false,

    fn run(self: *Dfs, i: usize, mines_so_far: usize) void {
        if (self.aborted) return;
        self.node_count += 1;
        if (self.node_count > NODE_BUDGET) {
            self.aborted = true;
            return;
        }
        if (i == self.comp.vars.len) {
            self.count_by_k[mines_so_far] += 1;
            for (self.assignment, 0..) |is_mine, vi| {
                if (is_mine) self.mine_count_by_k[vi][mines_so_far] += 1;
            }
            return;
        }
        self.tryChoice(i, mines_so_far, false);
        if (self.aborted) return;
        self.tryChoice(i, mines_so_far, true);
    }

    fn tryChoice(self: *Dfs, i: usize, mines_so_far: usize, choice: bool) void {
        self.assignment[i] = choice;
        var ok = true;
        for (self.var_constraints[i].items) |ci| {
            self.assigned_count[ci] += 1;
            if (choice) self.assigned_mines[ci] += 1;
            const need = self.comp.constraints[ci].remaining;
            const am = self.assigned_mines[ci];
            const ac = self.assigned_count[ci];
            const tot: i32 = @intCast(self.comp.constraints[ci].vars.len);
            if (am > need or (need - am) > (tot - ac)) ok = false;
        }
        if (ok) self.run(i + 1, mines_so_far + @as(usize, if (choice) 1 else 0));
        for (self.var_constraints[i].items) |ci| {
            self.assigned_count[ci] -= 1;
            if (choice) self.assigned_mines[ci] -= 1;
        }
    }
};

fn solveComponent(a: std.mem.Allocator, comp: *const Component) !CompResult {
    const n = comp.vars.len;
    const count_by_k = try a.alloc(u64, n + 1);
    @memset(count_by_k, 0);
    const mine_count_by_k = try a.alloc([]u64, n);
    for (mine_count_by_k) |*row| {
        row.* = try a.alloc(u64, n + 1);
        @memset(row.*, 0);
    }

    const nc = comp.constraints.len;
    const assigned_mines = try a.alloc(i32, nc);
    @memset(assigned_mines, 0);
    const assigned_count = try a.alloc(i32, nc);
    @memset(assigned_count, 0);

    const var_constraints = try a.alloc(std.ArrayList(usize), n);
    for (var_constraints) |*l| l.* = .empty;
    for (comp.constraints, 0..) |c, ci| {
        for (c.vars) |vi| try var_constraints[vi].append(a, ci);
    }

    const assignment = try a.alloc(bool, n);

    var dfs = Dfs{
        .comp = comp,
        .var_constraints = var_constraints,
        .assigned_mines = assigned_mines,
        .assigned_count = assigned_count,
        .assignment = assignment,
        .count_by_k = count_by_k,
        .mine_count_by_k = mine_count_by_k,
    };
    dfs.run(0, 0);

    return .{ .count_by_k = count_by_k, .mine_count_by_k = mine_count_by_k, .exact = !dfs.aborted };
}

// Combining a component's mine-count distribution with "however many mines
// are left over the rest of the board" involves binomial coefficients like
// C(2000, 99), which overflow f64 (and would blow past u64/u128 too once
// several such terms get multiplied together across components). Working
// in log-space and only exponentiating right before returning a probability
// (a value that's mathematically guaranteed to land in [0, 1], see the
// argument in computeProbabilities below) sidesteps that entirely.
fn logFactorialTable(a: std.mem.Allocator, max_n: usize) ![]f64 {
    const t = try a.alloc(f64, max_n + 1);
    t[0] = 0;
    var i: usize = 1;
    while (i <= max_n) : (i += 1) t[i] = t[i - 1] + @log(@as(f64, @floatFromInt(i)));
    return t;
}

fn logC(table: []const f64, n: usize, k: usize) f64 {
    if (k > n) return NEG_INF;
    return table[n] - table[k] - table[n - k];
}

fn logAdd(x: f64, y: f64) f64 {
    if (isNegInf(x)) return y;
    if (isNegInf(y)) return x;
    const m = @max(x, y);
    return m + @log(@exp(x - m) + @exp(y - m));
}

/// Log-space convolution: if x and y are the (log) mine-count distributions
/// of two independent regions, the result is the mine-count distribution of
/// the two regions combined. `cap` truncates the result to indices that
/// could ever matter (more mines than remain on the whole board never can),
/// which keeps this cheap even when one side is the "leftover" pool sized
/// to the entire board.
fn convolveLog(a: std.mem.Allocator, x: []const f64, y: []const f64, cap: usize) ![]f64 {
    const wanted_len = x.len + y.len - 1;
    const out_len = @min(wanted_len, cap + 1);
    const out = try a.alloc(f64, out_len);
    @memset(out, NEG_INF);
    for (x, 0..) |xv, i| {
        if (isNegInf(xv)) continue;
        var j: usize = 0;
        while (j < y.len) : (j += 1) {
            const k = i + j;
            if (k >= out_len) break;
            const yv = y[j];
            if (isNegInf(yv)) continue;
            out[k] = logAdd(out[k], xv + yv);
        }
    }
    return out;
}

pub fn computeProbabilities(a: std.mem.Allocator, board: Board, ded: *const Deduction) !ProbabilityResult {
    const n = board.width * board.height;
    const probabilities = try a.alloc(f64, n);
    @memset(probabilities, -1);

    var known_mine_count: usize = 0;
    for (0..n) |i| {
        if (ded.isKnownMine(board, i)) known_mine_count += 1;
    }
    const mines_remaining: usize = if (board.total_mines > known_mine_count)
        board.total_mines - known_mine_count
    else
        0;

    const constraints = try rules.buildConstraints(a, board, ded);

    // Assign each still-unknown, constrained cell a dense variable index.
    var var_of_cell = try a.alloc(?usize, n);
    @memset(var_of_cell, null);
    var cell_of_var: std.ArrayList(usize) = .empty;
    for (constraints) |c| {
        for (c.cells) |ci| {
            if (var_of_cell[ci] == null) {
                var_of_cell[ci] = cell_of_var.items.len;
                try cell_of_var.append(a, ci);
            }
        }
    }
    const num_vars = cell_of_var.items.len;

    // Fill in cells already resolved / known, and gather the leftover
    // (unconstrained) hidden cell pool.
    var leftover: std.ArrayList(usize) = .empty;
    for (0..n) |i| {
        if (board.state[i] != .hidden) continue;
        if (ded.mine[i]) {
            probabilities[i] = 1.0;
            continue;
        }
        if (ded.safe[i]) {
            probabilities[i] = 0.0;
            continue;
        }
        if (var_of_cell[i] == null) try leftover.append(a, i);
    }
    for (0..n) |i| {
        if (board.state[i] == .flagged) probabilities[i] = 1.0;
    }

    if (num_vars == 0) {
        // No live constraints: everything unresolved is in the leftover
        // pool, so the classic uniform density applies.
        const p: f64 = if (leftover.items.len > 0)
            @as(f64, @floatFromInt(mines_remaining)) / @as(f64, @floatFromInt(leftover.items.len))
        else
            0.0;
        for (leftover.items) |ci| probabilities[ci] = p;
        return .{ .probabilities = probabilities, .exact = true, .newly_safe = &.{}, .newly_mine = &.{} };
    }

    // Clues that share no unknown cell are independent, and the number of
    // valid mine placements grows exponentially with variable count -- so
    // instead of one enumeration over the whole frontier, split it into
    // connected components (union-find over "these two cells are pinned
    // together by some clue") and enumerate each separately. They get
    // recombined below via convolution.
    const parent = try a.alloc(usize, num_vars);
    for (parent, 0..) |*p, i| p.* = i;
    for (constraints) |c| {
        if (c.cells.len == 0) continue;
        const first = var_of_cell[c.cells[0]].?;
        for (c.cells[1..]) |ci| unite(parent, first, var_of_cell[ci].?);
    }

    var comp_id_of_root = try a.alloc(?usize, num_vars);
    @memset(comp_id_of_root, null);
    var comp_id_of_var = try a.alloc(usize, num_vars);
    var num_components: usize = 0;
    for (0..num_vars) |v| {
        const r = find(parent, v);
        if (comp_id_of_root[r] == null) {
            comp_id_of_root[r] = num_components;
            num_components += 1;
        }
        comp_id_of_var[v] = comp_id_of_root[r].?;
    }

    const comp_var_lists = try a.alloc(std.ArrayList(usize), num_components);
    for (comp_var_lists) |*l| l.* = .empty;
    const local_index_of_var = try a.alloc(usize, num_vars);
    for (0..num_vars) |v| {
        const comp = comp_id_of_var[v];
        try comp_var_lists[comp].append(a, v);
        local_index_of_var[v] = comp_var_lists[comp].items.len - 1;
    }

    const comp_constraint_lists = try a.alloc(std.ArrayList(LocalConstraint), num_components);
    for (comp_constraint_lists) |*l| l.* = .empty;
    for (constraints) |c| {
        if (c.cells.len == 0) continue;
        const comp = comp_id_of_var[var_of_cell[c.cells[0]].?];
        const locals = try a.alloc(usize, c.cells.len);
        for (c.cells, 0..) |ci, i| locals[i] = local_index_of_var[var_of_cell[ci].?];
        try comp_constraint_lists[comp].append(a, .{ .remaining = c.remaining, .vars = locals });
    }

    const components = try a.alloc(Component, num_components);
    for (0..num_components) |c| {
        const cells = try a.alloc(usize, comp_var_lists[c].items.len);
        for (comp_var_lists[c].items, 0..) |v, i| cells[i] = cell_of_var.items[v];
        components[c] = .{
            .vars = comp_var_lists[c].items,
            .cells = cells,
            .constraints = comp_constraint_lists[c].items,
        };
    }

    const comp_results = try a.alloc(CompResult, num_components);
    var all_exact = true;
    for (components, 0..) |*comp, c| {
        comp_results[c] = try solveComponent(a, comp);
        if (!comp_results[c].exact) all_exact = false;
    }

    var newly_safe: std.ArrayList(usize) = .empty;
    var newly_mine: std.ArrayList(usize) = .empty;

    if (all_exact) {
        const max_n = @max(leftover.items.len, n) + 1;
        const logfact = try logFactorialTable(a, max_n);

        // A component's own enumeration only tells you how many ways *it*
        // can place k mines -- not whether k is plausible board-wide. That
        // depends on how many mines the rest of the board (other
        // components, plus the unconstrained leftover pool) could still
        // absorb. So: treat the leftover pool as one more "component" whose
        // mine-count distribution is just C(leftover_cells, m) -- any m of
        // them could be a mine, no clue says otherwise -- and line every
        // component + the leftover pool up as one list to combine.
        const items_count = num_components + 1;
        var item_dist = try a.alloc([]f64, items_count);
        for (0..num_components) |c| {
            const dist = try a.alloc(f64, comp_results[c].count_by_k.len);
            for (comp_results[c].count_by_k, 0..) |cnt, k| {
                dist[k] = if (cnt == 0) NEG_INF else @log(@as(f64, @floatFromInt(cnt)));
            }
            item_dist[c] = dist;
        }
        const leftover_cap = @min(leftover.items.len, mines_remaining);
        const leftover_dist = try a.alloc(f64, leftover_cap + 1);
        for (0..leftover_cap + 1) |m| leftover_dist[m] = logC(logfact, leftover.items.len, m);
        item_dist[num_components] = leftover_dist;

        // A cell's mine probability needs "every item except the one it's
        // in, convolved together" (see the loop below). Recomputing that
        // exclusion from scratch per item would be O(items^2); prefix[t] /
        // suffix[t] hold the running convolution of items [0,t) and [t,end)
        // respectively, so "all but item i" is just prefix[i] * suffix[i+1]
        // -- the standard prefix/suffix-product trick, in log-space.
        var prefix = try a.alloc([]f64, items_count + 1);
        prefix[0] = try a.alloc(f64, 1);
        prefix[0][0] = 0;
        for (0..items_count) |t| prefix[t + 1] = try convolveLog(a, prefix[t], item_dist[t], mines_remaining);

        var suffix = try a.alloc([]f64, items_count + 1);
        suffix[items_count] = try a.alloc(f64, 1);
        suffix[items_count][0] = 0;
        var t = items_count;
        while (t > 0) : (t -= 1) suffix[t - 1] = try convolveLog(a, item_dist[t - 1], suffix[t], mines_remaining);

        // logZ = log(total ways to place mines_remaining mines across the
        // whole board consistent with every clue) -- the normalizing
        // constant every per-cell probability below is divided by.
        const logZ = if (mines_remaining < prefix[items_count].len) prefix[items_count][mines_remaining] else NEG_INF;

        if (isNegInf(logZ)) {
            all_exact = false; // infeasible/contradictory knowledge; fall back below.
        } else {
            for (components, 0..) |*comp, c| {
                const rest = try convolveLog(a, prefix[c], suffix[c + 1], mines_remaining);
                for (comp.vars, 0..) |_, li| {
                    const cell = comp.cells[li];
                    var p: f64 = 0;
                    const row = comp_results[c].mine_count_by_k[li];
                    for (row, 0..) |mc, k| {
                        if (mc == 0) continue;
                        if (k > mines_remaining) continue;
                        const r_idx = mines_remaining - k;
                        if (r_idx >= rest.len) continue;
                        const rv = rest[r_idx];
                        if (isNegInf(rv)) continue;
                        p += @as(f64, @floatFromInt(mc)) * @exp(rv - logZ);
                    }
                    probabilities[cell] = p;
                    if (p <= 1e-9) try newly_safe.append(a, cell);
                    if (p >= 1.0 - 1e-9) try newly_mine.append(a, cell);
                }
            }

            if (leftover.items.len > 0) {
                const rest_leftover = try convolveLog(a, prefix[num_components], suffix[num_components + 1], mines_remaining);
                var e_leftover: f64 = 0;
                for (leftover_dist, 0..) |dv, m| {
                    if (isNegInf(dv)) continue;
                    if (m > mines_remaining) continue;
                    const r_idx = mines_remaining - m;
                    if (r_idx >= rest_leftover.len) continue;
                    const rv = rest_leftover[r_idx];
                    if (isNegInf(rv)) continue;
                    e_leftover += @as(f64, @floatFromInt(m)) * @exp(dv + rv - logZ);
                }
                const p_leftover = e_leftover / @as(f64, @floatFromInt(leftover.items.len));
                for (leftover.items) |ci| probabilities[ci] = p_leftover;
                if (p_leftover <= 1e-9) {
                    for (leftover.items) |ci| try newly_safe.append(a, ci);
                } else if (p_leftover >= 1.0 - 1e-9) {
                    for (leftover.items) |ci| try newly_mine.append(a, ci);
                }
            }
        }
    }

    if (!all_exact) {
        // Pathologically large frontier: fall back to per-component marginal
        // probabilities (exact within a component, but not coupled to the
        // global mine count) and mean-field estimates where even that
        // blew the node budget.
        var expected_mines_in_components: f64 = 0;
        for (components, 0..) |*comp, c| {
            if (comp_results[c].exact) {
                var total: f64 = 0;
                for (comp_results[c].count_by_k) |cnt| total += @floatFromInt(cnt);
                var ek: f64 = 0;
                for (comp_results[c].count_by_k, 0..) |cnt, k| ek += @as(f64, @floatFromInt(k)) * @as(f64, @floatFromInt(cnt));
                ek /= total;
                expected_mines_in_components += ek;
                for (comp.vars, 0..) |_, li| {
                    const cell = comp.cells[li];
                    var mc_total: f64 = 0;
                    for (comp_results[c].mine_count_by_k[li]) |mc| mc_total += @floatFromInt(mc);
                    const p = mc_total / total;
                    probabilities[cell] = p;
                    if (p <= 1e-9) try newly_safe.append(a, cell);
                    if (p >= 1.0 - 1e-9) try newly_mine.append(a, cell);
                }
            } else {
                for (comp.constraints) |lc| {
                    const local_p = @as(f64, @floatFromInt(lc.remaining)) / @as(f64, @floatFromInt(lc.vars.len));
                    for (lc.vars) |li| {
                        const cell = comp.cells[li];
                        const prev = probabilities[cell];
                        probabilities[cell] = if (prev < 0) local_p else @max(prev, local_p);
                    }
                }
                for (comp.vars, 0..) |_, li| expected_mines_in_components += probabilities[comp.cells[li]];
            }
        }
        if (leftover.items.len > 0) {
            const remaining_f = @as(f64, @floatFromInt(mines_remaining)) - expected_mines_in_components;
            const clamped = std.math.clamp(remaining_f, 0, @as(f64, @floatFromInt(leftover.items.len)));
            const p_leftover = clamped / @as(f64, @floatFromInt(leftover.items.len));
            for (leftover.items) |ci| probabilities[ci] = p_leftover;
        }
    }

    return .{
        .probabilities = probabilities,
        .exact = all_exact,
        .newly_safe = try newly_safe.toOwnedSlice(a),
        .newly_mine = try newly_mine.toOwnedSlice(a),
    };
}

test "single isolated clue yields exact probability" {
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
    const result = try computeProbabilities(a, board, &ded);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.probabilities[board.idx(1, 0)], 1e-9);
}
