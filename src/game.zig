const std = @import("std");
const board_mod = @import("board.zig");
const Board = board_mod.Board;
const Coord = board_mod.Coord;

pub const RevealOutcome = enum { safe, mine, already_revealed };

/// A live, playable minesweeper game: a `Board` (what the solver can see)
/// plus a hidden ground-truth mine layout it is never given direct access
/// to -- moves only learn the truth by revealing.
pub const Game = struct {
    allocator: std.mem.Allocator,
    board: Board,
    mines: []bool,
    mines_placed: bool,
    revealed_count: usize,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize, total_mines: usize) !Game {
        const board = try Board.init(allocator, width, height, total_mines);
        const mines = try allocator.alloc(bool, width * height);
        @memset(mines, false);
        return .{
            .allocator = allocator,
            .board = board,
            .mines = mines,
            .mines_placed = false,
            .revealed_count = 0,
        };
    }

    pub fn deinit(self: *Game) void {
        self.board.deinit();
        self.allocator.free(self.mines);
        self.* = undefined;
    }

    /// Places mines uniformly at random, excluding (safe_x, safe_y) and its
    /// 8 neighbors so the very first click is always guaranteed safe --
    /// matching standard minesweeper fairness rules.
    fn placeMines(self: *Game, rng: std.Random, safe_x: usize, safe_y: usize) !void {
        const n = self.board.width * self.board.height;
        var pool: std.ArrayList(usize) = .empty;
        defer pool.deinit(self.allocator);
        try pool.ensureTotalCapacityPrecise(self.allocator, n);

        var buf: [8]Coord = undefined;
        const safe_ns = self.board.neighbors(safe_x, safe_y, &buf);

        var i: usize = 0;
        outer: while (i < n) : (i += 1) {
            const c = self.board.coordOf(i);
            if (c.x == safe_x and c.y == safe_y) continue;
            for (safe_ns) |sn| {
                if (sn.x == c.x and sn.y == c.y) continue :outer;
            }
            pool.appendAssumeCapacity(i);
        }

        const take = @min(self.board.total_mines, pool.items.len);
        var k: usize = 0;
        while (k < take) : (k += 1) {
            const j = k + rng.intRangeLessThan(usize, 0, pool.items.len - k);
            const tmp = pool.items[k];
            pool.items[k] = pool.items[j];
            pool.items[j] = tmp;
            self.mines[pool.items[k]] = true;
        }
        self.mines_placed = true;
    }

    fn adjacentMineCount(self: *Game, x: usize, y: usize) u8 {
        var buf: [8]Coord = undefined;
        const ns = self.board.neighbors(x, y, &buf);
        var c: u8 = 0;
        for (ns) |nb| {
            if (self.mines[self.board.idx(nb.x, nb.y)]) c += 1;
        }
        return c;
    }

    /// Reveals (x, y). Lazily places mines on the very first call so the
    /// opening click can be guaranteed safe. Flood-fills outward through
    /// connected zero cells, exactly like real minesweeper.
    pub fn reveal(self: *Game, rng: std.Random, x: usize, y: usize) !RevealOutcome {
        if (!self.mines_placed) try self.placeMines(rng, x, y);
        const start_idx = self.board.idx(x, y);
        if (self.board.state[start_idx] != .hidden) return .already_revealed;

        if (self.mines[start_idx]) {
            self.board.state[start_idx] = .revealed;
            return .mine;
        }

        var queue: std.ArrayList(Coord) = .empty;
        defer queue.deinit(self.allocator);
        try queue.append(self.allocator, .{ .x = x, .y = y });

        var head: usize = 0;
        var buf: [8]Coord = undefined;
        while (head < queue.items.len) : (head += 1) {
            const cur = queue.items[head];
            const ci = self.board.idx(cur.x, cur.y);
            if (self.board.state[ci] == .revealed) continue;
            const count = self.adjacentMineCount(cur.x, cur.y);
            self.board.state[ci] = .revealed;
            self.board.numbers[ci] = count;
            self.revealed_count += 1;
            if (count == 0) {
                const ns = self.board.neighbors(cur.x, cur.y, &buf);
                for (ns) |nb| {
                    const ni = self.board.idx(nb.x, nb.y);
                    if (self.board.state[ni] == .hidden and !self.mines[ni]) {
                        try queue.append(self.allocator, nb);
                    }
                }
            }
        }
        return .safe;
    }

    pub fn isWon(self: Game) bool {
        return self.revealed_count == self.board.width * self.board.height - self.board.total_mines;
    }

    /// Renders the board with ground truth overlaid (mines shown as '*'),
    /// intended for the post-game summary.
    pub fn renderWithTruth(self: Game, w: *std.Io.Writer) !void {
        var y: usize = 0;
        while (y < self.board.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.board.width) : (x += 1) {
                const i = self.board.idx(x, y);
                if (self.mines[i]) {
                    try w.writeByte('*');
                } else switch (self.board.state[i]) {
                    .hidden => try w.writeByte('?'),
                    .flagged => try w.writeByte('F'),
                    .revealed => {
                        const num = self.board.numbers[i];
                        if (num == 0) try w.writeByte('.') else try w.print("{d}", .{num});
                    },
                }
                if (x + 1 < self.board.width) try w.writeByte(' ');
            }
            try w.writeByte('\n');
        }
    }
};
