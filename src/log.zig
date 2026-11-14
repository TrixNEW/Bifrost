const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Level = enum(u8) {
    err,
    warn,
    info,
    debug,
    trace,

    pub fn parse(text: []const u8) ?Level {
        if (std.mem.eql(u8, text, "error")) return .err;
        const level = std.meta.stringToEnum(Level, text) orelse return null;
        return if (level == .err) null else level;
    }

    fn label(level: Level) []const u8 {
        return switch (level) {
            .err => "ERROR",
            .warn => "WARN ",
            .info => "INFO ",
            .debug => "DEBUG",
            .trace => "TRACE",
        };
    }

    fn color(level: Level) Io.Terminal.Color {
        return switch (level) {
            .err => .red,
            .warn => .yellow,
            .info => .green,
            .debug => .cyan,
            .trace => .bright_black,
        };
    }
};

pub const Color = enum { auto, always, never };

pub const Settings = struct {
    level: Level = .info,
    color: Color = .auto,
    timestamps: bool = true,
    file: ?[]const u8 = null,
    file_level: Level = .info,
    file_max_bytes: u64 = 16 * 1024 * 1024,
};

pub const max_path_len = 1024;
const max_message_len = 1024;

const State = struct {
    console: Level = .info,
    color: Color = .auto,
    timestamps: bool = true,
    file: ?Io.File = null,
    file_level: Level = .info,
    file_size: u64 = 0,
    file_max_bytes: u64 = 0,
    path: [max_path_len]u8 = undefined,
    path_len: usize = 0,
};

// Written only under the stderr lock, which every line is printed under too
var state: State = .{};
// The most verbose level any destination takes, so disabled calls never format
var threshold: std.atomic.Value(u8) = .init(@backingInt(Level.info));

pub fn enabled(level: Level) bool {
    return @backingInt(level) <= threshold.load(.monotonic);
}

/// `std.log` with a `trace` level below `debug`.
pub fn scoped(comptime scope: @EnumLiteral()) type {
    return struct {
        const base = std.log.scoped(scope);
        pub const err = base.err;
        pub const warn = base.warn;
        pub const info = base.info;
        pub const debug = base.debug;

        pub fn trace(comptime format: []const u8, args: anytype) void {
            if (enabled(.trace)) write(.trace, scope, format, args);
        }
    };
}

/// For `std_options.logFn`, so library logs share the format and levels.
pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const ours: Level = switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
    if (enabled(ours)) write(ours, scope, format, args);
}

/// Opens the log file, if any, before taking the new settings, so a bad path keeps the old ones.
/// An existing log becomes `<file>.1`, so each run starts a fresh file.
pub fn configure(settings: Settings) !void {
    const io = std.Options.debug_io;
    var opened: ?Io.File = null;
    if (settings.file) |path| {
        if (path.len == 0 or path.len > max_path_len) return error.NameTooLong;
        if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
        opened = try openFresh(io, path);
    }
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var none: [0]u8 = .{};
    _ = io.lockStderr(&none, null) catch unreachable;
    defer io.unlockStderr();
    closeFile(io);
    state = .{
        .console = settings.level,
        .color = settings.color,
        .timestamps = settings.timestamps,
        .file = opened,
        .file_level = settings.file_level,
        .file_max_bytes = @max(settings.file_max_bytes, 64 * 1024),
    };
    if (settings.file) |path| {
        @memcpy(state.path[0..path.len], path);
        state.path_len = path.len;
    }
    updateThreshold();
}

/// Closes the log file; later lines only reach the console.
pub fn deinit() void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var none: [0]u8 = .{};
    _ = io.lockStderr(&none, null) catch unreachable;
    defer io.unlockStderr();
    closeFile(io);
    updateThreshold();
}

fn closeFile(io: Io) void {
    if (state.file) |file| file.close(io);
    state.file = null;
}

fn updateThreshold() void {
    const file_level = if (state.file != null) state.file_level else .err;
    threshold.store(@max(@backingInt(state.console), @backingInt(file_level)), .monotonic);
}

fn write(comptime level: Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    var buffer: [max_message_len]u8 = undefined;
    emit(level, comptime category(scope), render(&buffer, format, args));
}

fn category(comptime scope: @EnumLiteral()) []const u8 {
    const name = comptime switch (scope) {
        .default => "Bifrost",
        .nethernet => "NetherNet",
        else => blk: {
            var text = @tagName(scope)[0..].*;
            text[0] = std.ascii.toUpper(text[0]);
            const final = text;
            break :blk &final;
        },
    };
    return std.fmt.comptimePrint("{s:<10}", .{name});
}

// Names and reasons can come from players, so control bytes can't break a line or reach the terminal
fn render(buffer: []u8, comptime format: []const u8, args: anytype) []u8 {
    var w: Io.Writer = .fixed(buffer);
    var text = buffer[0..w.end];
    if (w.print(format, args)) |_| {
        text = w.buffered();
    } else |_| {
        const end = @min(w.end + 3, buffer.len);
        @memcpy(buffer[end - 3 .. end], "...");
        text = buffer[0..end];
    }
    for (text) |*byte| {
        if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
    }
    return text;
}

fn emit(level: Level, name: []const u8, text: []const u8) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    const time = Time.now(io);
    var buffer: [256]u8 = undefined;
    const stderr = io.lockStderr(&buffer, null) catch unreachable;
    defer io.unlockStderr();
    var terminal = stderr.terminal();
    switch (state.color) {
        .auto => {},
        .always => terminal.mode = .escape_codes,
        .never => terminal.mode = .no_color,
    }
    if (@backingInt(level) <= @backingInt(state.console)) printConsole(terminal, level, name, text, if (state.timestamps) time else null) catch {};
    if (state.file != null and @backingInt(level) <= @backingInt(state.file_level)) writeFile(io, terminal, level, name, text, time);
}

fn printConsole(t: Io.Terminal, level: Level, name: []const u8, text: []const u8, time: ?Time) Io.Writer.Error!void {
    if (time) |at| {
        t.setColor(.dim) catch {};
        try t.writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ at.hour, at.minute, at.second });
        t.setColor(.reset) catch {};
        try t.writer.writeAll("  ");
    }
    t.setColor(level.color()) catch {};
    try t.writer.writeAll(level.label());
    t.setColor(.reset) catch {};
    try t.writer.print("  {s} {s}\n", .{ name, text });
}

fn writeFile(io: Io, terminal: Io.Terminal, level: Level, name: []const u8, text: []const u8, time: Time) void {
    var buffer: [max_message_len + 64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    w.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}  {s}  {s} {s}\n", .{
        time.year, time.month, time.day, time.hour, time.minute, time.second, level.label(), name, text,
    }) catch unreachable;
    const line = w.buffered();
    if (state.file_size != 0 and state.file_size + line.len > state.file_max_bytes) {
        closeFile(io);
        state.file = openFresh(io, state.path[0..state.path_len]) catch |err| return fileFailed(terminal, err, time);
        state.file_size = 0;
    }
    state.file.?.writeStreamingAll(io, line) catch |err| return fileFailed(terminal, err, time);
    state.file_size += line.len;
}

// One previous file is kept, so the log never takes more than twice the limit
fn openFresh(io: Io, path: []const u8) !Io.File {
    var buffer: [max_path_len + 2]u8 = undefined;
    const previous = std.fmt.bufPrint(&buffer, "{s}.1", .{path}) catch unreachable;
    Io.Dir.cwd().rename(path, .cwd(), previous, io) catch {};
    return Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
}

fn fileFailed(terminal: Io.Terminal, err: anyerror, time: Time) void {
    closeFile(std.Options.debug_io);
    updateThreshold();
    var buffer: [max_message_len]u8 = undefined;
    const text = render(&buffer, "Log file {s} disabled: {t}", .{ state.path[0..state.path_len], err });
    printConsole(terminal, .err, comptime category(.log), text, if (state.timestamps) time else null) catch {};
}

const Time = struct {
    year: u32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    fn now(io: Io) Time {
        const seconds = Io.Clock.real.now(io).toSeconds();
        if (comptime builtin.link_libc) if (local(seconds)) |time| return time;
        return utc(seconds);
    }

    fn utc(seconds: i64) Time {
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = std.math.cast(u64, seconds) orelse 0 };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch.getDaySeconds();
        return .{
            .year = year_day.year,
            .month = month_day.month.numeric(),
            .day = month_day.day_index + 1,
            .hour = day_seconds.getHoursIntoDay(),
            .minute = day_seconds.getMinutesIntoHour(),
            .second = day_seconds.getSecondsIntoMinute(),
        };
    }

    fn local(seconds: i64) ?Time {
        var tm: Tm = undefined;
        if (builtin.os.tag == .windows) {
            if (_localtime64_s(&tm, &seconds) != 0) return null;
        } else {
            const time: std.c.time_t = std.math.cast(std.c.time_t, seconds) orelse return null;
            if (localtime_r(&time, &tm) == null) return null;
        }
        return .{
            .year = std.math.cast(u32, tm.year + 1900) orelse return null,
            .month = std.math.cast(u8, tm.mon + 1) orelse return null,
            .day = std.math.cast(u8, tm.mday) orelse return null,
            .hour = std.math.cast(u8, tm.hour) orelse return null,
            .minute = std.math.cast(u8, tm.min) orelse return null,
            .second = std.math.cast(u8, @min(tm.sec, 59)) orelse return null,
        };
    }
};

// The leading fields every libc shares, with room for the extras glibc and BSDs add
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    extra: [4]usize,
};

extern "c" fn localtime_r(time: *const std.c.time_t, result: *Tm) ?*Tm;
extern "c" fn _localtime64_s(result: *Tm, time: *const i64) c_int;

/// Prints milliseconds the way people read them: 342ms, 4.2s, 12m 5s, 3h 20m.
pub fn elapsed(ms: u64) Elapsed {
    return .{ .ms = ms };
}

pub const Elapsed = struct {
    ms: u64,

    pub fn format(self: Elapsed, w: *Io.Writer) Io.Writer.Error!void {
        const s = self.ms / 1000;
        if (self.ms < 1000) return w.print("{d}ms", .{self.ms});
        if (s < 60) return w.print("{d}.{d}s", .{ s, self.ms % 1000 / 100 });
        if (s < 3600) return w.print("{d}m {d}s", .{ s / 60, s % 60 });
        return w.print("{d}h {d}m", .{ s / 3600, s % 3600 / 60 });
    }
};

test "levels parse by their config names" {
    try std.testing.expectEqual(Level.err, Level.parse("error").?);
    try std.testing.expectEqual(Level.trace, Level.parse("trace").?);
    try std.testing.expect(Level.parse("err") == null);
    try std.testing.expect(Level.parse("verbose") == null);
}

test "categories are capitalized and padded" {
    try std.testing.expectEqualStrings("NetherNet ", category(.nethernet));
    try std.testing.expectEqualStrings("Backend   ", category(.backend));
    try std.testing.expectEqualStrings("Bifrost   ", category(.default));
}

test "messages are sanitized and truncated" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a b c", render(&buffer, "{s}", .{"a\nb\x1bc"}));
    try std.testing.expectEqualStrings("0123456789abc...", render(&buffer, "{s}", .{"0123456789abcdefghij"}));
}

test "console lines line up with and without color" {
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try printConsole(.{ .writer = &w, .mode = .no_color }, .warn, category(.backend), "lobby is down", .{ .year = 2026, .month = 1, .day = 2, .hour = 3, .minute = 4, .second = 5 });
    try std.testing.expectEqualStrings("03:04:05  WARN   Backend    lobby is down\n", w.buffered());
    w = .fixed(&buffer);
    try printConsole(.{ .writer = &w, .mode = .escape_codes }, .err, category(.server), "x", null);
    try std.testing.expectEqualStrings("\x1b[31mERROR\x1b[0m  Server     x\n", w.buffered());
}

test "elapsed time reads naturally" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("342ms", try std.fmt.bufPrint(&buffer, "{f}", .{elapsed(342)}));
    try std.testing.expectEqualStrings("4.2s", try std.fmt.bufPrint(&buffer, "{f}", .{elapsed(4_250)}));
    try std.testing.expectEqualStrings("12m 5s", try std.fmt.bufPrint(&buffer, "{f}", .{elapsed(725_000)}));
    try std.testing.expectEqualStrings("3h 20m", try std.fmt.bufPrint(&buffer, "{f}", .{elapsed(12_000_000)}));
}

test "the log file rotates at its limit and keeps one previous file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/logs/bifrost.log", .{tmp.sub_path});
    try configure(.{ .level = .err, .file = path, .file_level = .debug, .file_max_bytes = 64 * 1024 });
    defer configure(.{}) catch {};
    try std.testing.expect(enabled(.debug));
    try std.testing.expect(!enabled(.trace));
    const line: [900]u8 = @splat('x');
    for (0..100) |_| write(.info, .server, "{s}", .{&line});
    write(.debug, .server, "last", .{});
    deinit();
    try std.testing.expect(!enabled(.debug));

    const io = std.testing.io;
    const current = try tmp.dir.statFile(io, "logs/bifrost.log", .{});
    const previous = try tmp.dir.statFile(io, "logs/bifrost.log.1", .{});
    try std.testing.expect(current.size <= 64 * 1024 and previous.size <= 64 * 1024);
    try std.testing.expect(previous.size > 60 * 1024);
    var content: [64 * 1024]u8 = undefined;
    const text = try tmp.dir.readFile(io, "logs/bifrost.log", &content);
    try std.testing.expect(std.mem.endsWith(u8, text, "  DEBUG  Server     last\n"));
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x1b) == null);
}
