const std = @import("std");
const board_mod = @import("board.zig");
const engine = @import("solver/engine.zig");
const game_mod = @import("game.zig");

const Board = board_mod.Board;

const usage =
    \\Torpedo -- an advanced minesweeper solver/bot.
    \\
    \\USAGE:
    \\  torpedo solve <board-file> [options]
    \\  torpedo play --width W --height H --mines M [options]
    \\  torpedo help
    \\
    \\SOLVE reads a scrambled board from a text file and reports every cell
    \\it can prove safe or mined, plus (when a guess is unavoidable) the
    \\lowest-risk cell to click, computed via exact combinatorial CSP.
    \\
    \\PLAY generates a fresh random board and plays it start to finish on
    \\its own, printing each move.
    \\
    \\Board file format:
    \\  line 1:   "<width> <height> <mines>"
    \\  next H lines: W cell characters
    \\    ?  hidden      F  flagged (known mine)
    \\    .  revealed 0  0-8  revealed clue
    \\
    \\OPTIONS (both commands):
    \\  --elo N            Skill rating, like a chess engine (default 2800 =
    \\                     perfect play). Lower ratings think less deeply and
    \\                     occasionally blunder into a mine on purpose, to
    \\                     simulate a weaker opponent.
    \\  --think LEVEL      Force a thinking level regardless of elo:
    \\                       basic  - single-clue saturation only
    \\                       subset - + generalized subset elimination
    \\                       exact  - + exact CSP probability solving
    \\  --seed N           Seed the RNG (guess tie-breaks, blunders, mine
    \\                     placement in play mode). Default: time-based.
    \\  --show-probabilities  Print the full per-cell mine-probability grid.
    \\
    \\PLAY-only OPTIONS:
    \\  --width N --height N --mines N   Board size and mine count (required)
    \\  --start-x N --start-y N          First click (default: center)
    \\  --max-moves N                    Safety cap on turns (default: cells+5)
    \\  --quiet                          Only print the final result
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;
    defer w.flush() catch {};

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // argv[0]

    const cmd = it.next() orelse {
        try w.writeAll(usage);
        return;
    };

    if (std.mem.eql(u8, cmd, "solve")) {
        try cmdSolve(gpa, io, w, &it);
    } else if (std.mem.eql(u8, cmd, "play")) {
        try cmdPlay(gpa, io, w, &it);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try w.writeAll(usage);
    } else {
        try w.print("Unknown command '{s}'\n\n", .{cmd});
        try w.writeAll(usage);
        std.process.exit(1);
    }
}

const CommonOptions = struct {
    elo: f64 = 2800,
    think: ?engine.ThinkLevel = null,
    seed: ?u64 = null,
    show_probabilities: bool = false,
};

fn parseCommonFlag(opts: *CommonOptions, flag: []const u8, it: *std.process.Args.Iterator) !bool {
    if (std.mem.eql(u8, flag, "--elo")) {
        const v = it.next() orelse return error.MissingValue;
        opts.elo = std.fmt.parseFloat(f64, v) catch return error.BadValue;
        return true;
    } else if (std.mem.eql(u8, flag, "--think")) {
        const v = it.next() orelse return error.MissingValue;
        opts.think = engine.ThinkLevel.parse(v) orelse return error.BadValue;
        return true;
    } else if (std.mem.eql(u8, flag, "--seed")) {
        const v = it.next() orelse return error.MissingValue;
        opts.seed = std.fmt.parseInt(u64, v, 10) catch return error.BadValue;
        return true;
    } else if (std.mem.eql(u8, flag, "--show-probabilities")) {
        opts.show_probabilities = true;
        return true;
    }
    return false;
}

fn makeRng(io: std.Io, seed: ?u64) std.Random.DefaultPrng {
    const s = seed orelse blk: {
        const ts = std.Io.Timestamp.now(io, .real);
        break :blk @as(u64, @truncate(@as(u96, @bitCast(ts.nanoseconds))));
    };
    return std.Random.DefaultPrng.init(s);
}

fn cmdSolve(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, it: *std.process.Args.Iterator) !void {
    var opts = CommonOptions{};
    var path: ?[]const u8 = null;

    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) {
            const handled = parseCommonFlag(&opts, arg, it) catch |err| {
                try w.print("error: bad flag '{s}': {t}\n", .{ arg, err });
                std.process.exit(1);
            };
            if (!handled) {
                try w.print("error: unknown flag '{s}'\n", .{arg});
                std.process.exit(1);
            }
        } else if (path == null) {
            path = arg;
        }
    }

    const p = path orelse {
        try w.writeAll("error: solve requires a board file path\n\n");
        try w.writeAll(usage);
        std.process.exit(1);
    };

    const text = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        try w.print("error: could not read '{s}': {t}\n", .{ p, err });
        std.process.exit(1);
    };
    defer gpa.free(text);

    var board = Board.parse(gpa, text) catch |err| {
        try w.print("error: could not parse board '{s}': {t}\n", .{ p, err });
        std.process.exit(1);
    };
    defer board.deinit();

    try w.writeAll("Board:\n");
    try board.render(w);
    try w.writeByte('\n');

    var prng = makeRng(io, opts.seed);
    var analysis = try engine.analyze(gpa, board, opts.elo, opts.think, prng.random());
    defer analysis.deinit(gpa);

    try printAnalysis(w, board, &analysis, opts.elo);
    if (opts.show_probabilities) {
        try w.writeAll("\nMine probability grid:\n");
        try printProbabilityGrid(w, board, analysis.probabilities);
    }
}

fn cmdPlay(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, it: *std.process.Args.Iterator) !void {
    var opts = CommonOptions{};
    var width: ?usize = null;
    var height: ?usize = null;
    var mines: ?usize = null;
    var start_x: ?usize = null;
    var start_y: ?usize = null;
    var max_moves: ?usize = null;
    var quiet = false;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--width")) {
            width = std.fmt.parseInt(usize, it.next() orelse return error.MissingValue, 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--height")) {
            height = std.fmt.parseInt(usize, it.next() orelse return error.MissingValue, 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--mines")) {
            mines = std.fmt.parseInt(usize, it.next() orelse return error.MissingValue, 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--start-x")) {
            start_x = std.fmt.parseInt(usize, it.next() orelse return error.MissingValue, 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--start-y")) {
            start_y = std.fmt.parseInt(usize, it.next() orelse return error.MissingValue, 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--max-moves")) {
            max_moves = std.fmt.parseInt(usize, it.next() orelse return error.MissingValue, 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            const handled = parseCommonFlag(&opts, arg, it) catch |err| {
                try w.print("error: bad flag '{s}': {t}\n", .{ arg, err });
                std.process.exit(1);
            };
            if (!handled) {
                try w.print("error: unknown flag '{s}'\n", .{arg});
                std.process.exit(1);
            }
        }
    }

    const bw = width orelse {
        try w.writeAll("error: play requires --width, --height, --mines\n\n");
        try w.writeAll(usage);
        std.process.exit(1);
    };
    const bh = height orelse {
        try w.writeAll("error: play requires --height\n\n");
        std.process.exit(1);
    };
    const bm = mines orelse {
        try w.writeAll("error: play requires --mines\n\n");
        std.process.exit(1);
    };
    if (bm >= bw * bh) {
        try w.writeAll("error: mine count must be less than the number of cells\n");
        std.process.exit(1);
    }

    var prng = makeRng(io, opts.seed);
    const rng = prng.random();

    var g = try game_mod.Game.init(gpa, bw, bh, bm);
    defer g.deinit();

    const sx = start_x orelse bw / 2;
    const sy = start_y orelse bh / 2;
    if (sx >= bw or sy >= bh) {
        try w.writeAll("error: start position is outside the board\n");
        std.process.exit(1);
    }

    const profile = engine.profileForElo(opts.elo);
    try w.print("Torpedo playing {d}x{d}, {d} mines. Elo {d:.0} -- {s} (thinking: {s})\n\n", .{
        bw, bh, bm, opts.elo, profile.label, (opts.think orelse profile.think).label(),
    });

    const move_cap = max_moves orelse (bw * bh + 5);
    var move_num: usize = 0;
    var lost = false;

    var first_move = true;
    while (move_num < move_cap) : (move_num += 1) {
        var analysis = try engine.analyze(gpa, g.board, opts.elo, opts.think, rng);
        defer analysis.deinit(gpa);

        var target = analysis.chosen_move;
        if (first_move and target == null) target = .{ .x = sx, .y = sy };
        first_move = false;

        const move = target orelse break; // nothing left to do

        if (!quiet) {
            try w.print("Move {d}: click ({d},{d})", .{ move_num + 1, move.x, move.y });
            if (analysis.blundered) {
                try w.writeAll(" [BLUNDER]");
            } else if (analysis.is_guess) {
                try w.print(" [guess, {d:.1}% mine, {s}]", .{ analysis.move_probability * 100, if (analysis.exact) "exact" else "approx" });
            } else {
                try w.writeAll(" [certain safe]");
            }
            try w.writeByte('\n');
        }

        const outcome = try g.reveal(rng, move.x, move.y);
        switch (outcome) {
            .mine => {
                lost = true;
                if (!quiet) try w.writeAll("  -> hit a mine.\n");
            },
            .already_revealed => {},
            .safe => {},
        }

        if (lost or g.isWon()) break;
        if (!quiet) try w.flush();
    }

    try w.writeByte('\n');
    if (lost) {
        try w.writeAll("Result: LOSS\n");
    } else if (g.isWon()) {
        try w.writeAll("Result: WIN\n");
    } else {
        try w.writeAll("Result: STOPPED (move cap reached without a certain move)\n");
    }
    try w.print("Moves played: {d}, cells revealed: {d}/{d}\n\n", .{ move_num + 1, g.revealed_count, bw * bh - bm });

    try w.writeAll("Final board:\n");
    try g.renderWithTruth(w);
}

fn printAnalysis(w: *std.Io.Writer, board: Board, analysis: *const engine.Analysis, elo: f64) !void {
    try w.print("Elo {d:.0} -- {s} (thinking: {s}, reasoning: {s})\n", .{
        elo,
        analysis.profile.label,
        analysis.profile.think.label(),
        if (analysis.exact) "exact" else "approximate",
    });
    try w.print("Certain safe cells: {d}\n", .{analysis.certain_safe.len});
    try w.print("Certain mine cells: {d}\n", .{analysis.certain_mines.len});

    if (analysis.certain_safe.len > 0) {
        try w.writeAll("  safe: ");
        for (analysis.certain_safe, 0..) |c, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("({d},{d})", .{ c.x, c.y });
        }
        try w.writeByte('\n');
    }
    if (analysis.certain_mines.len > 0) {
        try w.writeAll("  mines: ");
        for (analysis.certain_mines, 0..) |c, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("({d},{d})", .{ c.x, c.y });
        }
        try w.writeByte('\n');
    }

    if (analysis.chosen_move) |move| {
        if (analysis.blundered) {
            try w.print("\nRecommended move: ({d},{d}) -- simulated blunder for this Elo level!\n", .{ move.x, move.y });
        } else if (!analysis.is_guess) {
            try w.print("\nRecommended move: ({d},{d}) -- 100% certain safe.\n", .{ move.x, move.y });
        } else {
            try w.print("\nRecommended move: ({d},{d}) -- no certain move exists; this is the lowest-risk guess at {d:.2}% mine probability.\n", .{ move.x, move.y, analysis.move_probability * 100 });
        }
    } else if (board.countHidden() == 0) {
        try w.writeAll("\nBoard is fully revealed. Nothing left to do.\n");
    } else {
        try w.writeAll("\nNo legal move found.\n");
    }
}

fn printProbabilityGrid(w: *std.Io.Writer, board: Board, probabilities: []const f64) !void {
    var y: usize = 0;
    while (y < board.height) : (y += 1) {
        var x: usize = 0;
        while (x < board.width) : (x += 1) {
            const i = board.idx(x, y);
            switch (board.state[i]) {
                .revealed => {
                    const num = board.getNumber(x, y);
                    if (num == 0) {
                        try w.print("{s:>5}", .{"."});
                    } else {
                        try w.print("{d:>5}", .{num});
                    }
                },
                .flagged => try w.print("{s:>5}", .{"F"}),
                .hidden => {
                    const p = probabilities[i];
                    if (p < 0) {
                        try w.print("{s:>5}", .{"?"});
                    } else {
                        const pct: i64 = @intFromFloat(@round(p * 100));
                        var buf: [8]u8 = undefined;
                        const s = try std.fmt.bufPrint(&buf, "{d}%", .{pct});
                        try w.print("{s:>5}", .{s});
                    }
                },
            }
        }
        try w.writeByte('\n');
    }
}

test {
    _ = @import("board.zig");
    _ = @import("game.zig");
    _ = @import("solver/rules.zig");
    _ = @import("solver/csp.zig");
    _ = @import("solver/engine.zig");
}
