const std = @import("std");

pub const Coord = struct {
    x: usize,
    y: usize,
};

pub const CellState = enum(u8) {
    hidden,
    flagged,
    revealed,
};

pub const ParseError = error{
    InvalidHeader,
    NotEnoughRows,
    RowTooShort,
    InvalidCell,
    TooManyMines,
    ZeroDimension,
};

/// The visible/known state of a minesweeper board, as a solver would see it.
/// This never stores ground-truth mine locations -- only what has been
/// revealed, flagged, or is still hidden.
pub const Board = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    total_mines: usize,
    state: []CellState,
    /// Valid only where state[i] == .revealed. 0-8.
    numbers: []u8,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize, total_mines: usize) !Board {
        const n = width * height;
        const state = try allocator.alloc(CellState, n);
        @memset(state, .hidden);
        const numbers = try allocator.alloc(u8, n);
        @memset(numbers, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .total_mines = total_mines,
            .state = state,
            .numbers = numbers,
        };
    }

    pub fn deinit(self: *Board) void {
        self.allocator.free(self.state);
        self.allocator.free(self.numbers);
        self.* = undefined;
    }

    pub fn idx(self: Board, x: usize, y: usize) usize {
        return y * self.width + x;
    }

    pub fn coordOf(self: Board, i: usize) Coord {
        return .{ .x = i % self.width, .y = i / self.width };
    }

    pub fn inBounds(self: Board, x: isize, y: isize) bool {
        return x >= 0 and y >= 0 and x < @as(isize, @intCast(self.width)) and y < @as(isize, @intCast(self.height));
    }

    pub fn get(self: Board, x: usize, y: usize) CellState {
        return self.state[self.idx(x, y)];
    }

    pub fn getNumber(self: Board, x: usize, y: usize) u8 {
        return self.numbers[self.idx(x, y)];
    }

    /// Fills `buf` with the in-bounds 8-neighborhood of (x, y) and returns
    /// the used prefix.
    pub fn neighbors(self: Board, x: usize, y: usize, buf: *[8]Coord) []Coord {
        var n: usize = 0;
        var dy: isize = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: isize = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                const nx = @as(isize, @intCast(x)) + dx;
                const ny = @as(isize, @intCast(y)) + dy;
                if (!self.inBounds(nx, ny)) continue;
                buf[n] = .{ .x = @intCast(nx), .y = @intCast(ny) };
                n += 1;
            }
        }
        return buf[0..n];
    }

    pub fn countHidden(self: Board) usize {
        var c: usize = 0;
        for (self.state) |s| {
            if (s == .hidden) c += 1;
        }
        return c;
    }

    pub fn countFlagged(self: Board) usize {
        var c: usize = 0;
        for (self.state) |s| {
            if (s == .flagged) c += 1;
        }
        return c;
    }

    pub fn countRevealed(self: Board) usize {
        var c: usize = 0;
        for (self.state) |s| {
            if (s == .revealed) c += 1;
        }
        return c;
    }

    /// Parses the human-editable board text format:
    ///   line 1: "<width> <height> <mines>"
    ///   next `height` lines: exactly `width` cell characters each
    ///     '?' hidden      'F' flagged (known mine, still hidden)
    ///     '.' revealed 0  '0'-'8' revealed count
    /// Blank lines are ignored. Whitespace within a row is stripped.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Board {
        var lines = std.mem.splitScalar(u8, text, '\n');

        var header: []const u8 = "";
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            header = trimmed;
            break;
        }
        if (header.len == 0) return ParseError.InvalidHeader;

        var header_it = std.mem.tokenizeAny(u8, header, " \t");
        const w_str = header_it.next() orelse return ParseError.InvalidHeader;
        const h_str = header_it.next() orelse return ParseError.InvalidHeader;
        const m_str = header_it.next() orelse return ParseError.InvalidHeader;
        const width = std.fmt.parseInt(usize, w_str, 10) catch return ParseError.InvalidHeader;
        const height = std.fmt.parseInt(usize, h_str, 10) catch return ParseError.InvalidHeader;
        const mines = std.fmt.parseInt(usize, m_str, 10) catch return ParseError.InvalidHeader;
        if (width == 0 or height == 0) return ParseError.ZeroDimension;
        if (mines > width * height) return ParseError.TooManyMines;

        var board = try Board.init(allocator, width, height, mines);
        errdefer board.deinit();

        var row: usize = 0;
        while (row < height) {
            const line = lines.next() orelse return ParseError.NotEnoughRows;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            var col: usize = 0;
            var i: usize = 0;
            while (col < width) {
                if (i >= trimmed.len) return ParseError.RowTooShort;
                const c = trimmed[i];
                i += 1;
                if (c == ' ' or c == '\t') continue;
                const cell_idx = board.idx(col, row);
                switch (c) {
                    '?' => board.state[cell_idx] = .hidden,
                    'F', 'f' => board.state[cell_idx] = .flagged,
                    '.' => {
                        board.state[cell_idx] = .revealed;
                        board.numbers[cell_idx] = 0;
                    },
                    '0'...'8' => {
                        board.state[cell_idx] = .revealed;
                        board.numbers[cell_idx] = c - '0';
                    },
                    else => return ParseError.InvalidCell,
                }
                col += 1;
            }
            row += 1;
        }

        return board;
    }

    /// Renders the board back out in the same glyph set `parse` reads:
    /// '?' hidden, 'F' flagged, '.' / '0'-'8' revealed. See
    /// `main.printProbabilityGrid` for the mine-probability overlay.
    pub fn render(self: Board, w: *std.Io.Writer) !void {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const s = self.get(x, y);
                switch (s) {
                    .hidden => try w.writeByte('?'),
                    .flagged => try w.writeByte('F'),
                    .revealed => {
                        const n = self.getNumber(x, y);
                        if (n == 0) {
                            try w.writeByte('.');
                        } else {
                            try w.print("{d}", .{n});
                        }
                    },
                }
                if (x + 1 < self.width) try w.writeByte(' ');
            }
            try w.writeByte('\n');
        }
    }
};

test "parse basic board" {
    const text =
        \\4 3 2
        \\? ? ? ?
        \\1 1 . .
        \\F ? 1 .
    ;
    var board = try Board.parse(std.testing.allocator, text);
    defer board.deinit();
    try std.testing.expectEqual(@as(usize, 4), board.width);
    try std.testing.expectEqual(@as(usize, 3), board.height);
    try std.testing.expectEqual(@as(usize, 2), board.total_mines);
    try std.testing.expectEqual(CellState.hidden, board.get(0, 0));
    try std.testing.expectEqual(CellState.flagged, board.get(0, 2));
    try std.testing.expectEqual(CellState.revealed, board.get(1, 1));
    try std.testing.expectEqual(@as(u8, 1), board.getNumber(1, 1));
}
