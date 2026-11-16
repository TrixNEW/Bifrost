const std = @import("std");
const builtin = @import("builtin");
const Log = @import("../log.zig");

/// Operator commands read from stdin, which is where Pterodactyl's console and `docker attach` type.
const Console = @This();
const log = Log.scoped(.console);

pub const max_name_len = 32;
pub const max_reason_len = 128;

pub const help =
    \\status                    players, backends and their health
    \\players                   everyone online
    \\find <player>             where a player is
    \\send <player> <backend>   transfers a player (managed sessions)
    \\kick <player> [reason]    disconnects a player; quote a name with spaces, as in kick "Some Name" spam
    \\drain <backend>           takes no new players or transfers there
    \\undrain <backend>         takes them again
    \\log <level>               console level: error, warn, info, debug or trace
    \\stop                      disconnects everyone and exits
;

pub const Command = union(enum) {
    help,
    status,
    players,
    find: []const u8,
    send: struct { player: []const u8, backend: []const u8 },
    kick: struct { player: []const u8, reason: []const u8 },
    drain: []const u8,
    undrain: []const u8,
    log: Log.Level,
    stop,
};

pub const ParseError = error{ UnknownCommand, Usage };

const blank = " \t\r";

/// Null for a blank line. Gamertags can hold spaces, so a name runs to the end of the line, up to the backend for
/// `send`, or is quoted for `kick`.
pub fn parse(line: []const u8) ParseError!?Command {
    const text = std.mem.trim(u8, line, blank);
    if (text.len == 0) return null;
    const split = std.mem.indexOfAny(u8, text, blank) orelse text.len;
    const args = std.mem.trimStart(u8, text[split..], blank);
    const Verb = enum { help, status, players, list, find, send, kick, drain, undrain, log, stop, end };
    const verb = std.meta.stringToEnum(Verb, text[0..split]) orelse return error.UnknownCommand;
    return switch (verb) {
        .help => .help,
        .status => .status,
        .players, .list => .players,
        .stop, .end => .stop,
        .find => .{ .find = try player(args) },
        .drain => .{ .drain = try word(args) },
        .undrain => .{ .undrain = try word(args) },
        .log => .{ .log = Log.Level.parse(try word(args)) orelse return error.Usage },
        .send => send: {
            const last = std.mem.lastIndexOfAny(u8, args, blank) orelse return error.Usage;
            break :send .{ .send = .{ .player = try player(args[0..last]), .backend = args[last + 1 ..] } };
        },
        .kick => kick: {
            const quoted = args.len != 0 and args[0] == '"';
            const end = if (quoted)
                (std.mem.indexOfScalarPos(u8, args, 1, '"') orelse return error.Usage) + 1
            else
                std.mem.indexOfAny(u8, args, blank) orelse args.len;
            const reason = std.mem.trim(u8, args[end..], blank);
            break :kick .{ .kick = .{ .player = try player(args[0..end]), .reason = reason[0..@min(reason.len, max_reason_len)] } };
        },
    };
}

fn player(text: []const u8) ParseError![]const u8 {
    var name = std.mem.trim(u8, text, blank);
    if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') name = name[1 .. name.len - 1];
    if (name.len == 0 or name.len > max_name_len) return error.Usage;
    return name;
}

fn word(text: []const u8) ParseError![]const u8 {
    if (text.len == 0 or std.mem.indexOfAny(u8, text, blank) != null) return error.Usage;
    return text;
}

pub const Request = struct {
    action: enum { list, find, send, kick },
    name_storage: [max_name_len]u8 = undefined,
    name_len: u8 = 0,
    backend: u8 = 0,
    reason_storage: [max_reason_len]u8 = undefined,
    reason_len: u8 = 0,
    reply: *Reply,

    pub fn init(action: @FieldType(Request, "action"), who: []const u8, text: []const u8, reply: *Reply) Request {
        var self: Request = .{ .action = action, .reply = reply };
        self.name_len = @intCast(@min(who.len, max_name_len));
        @memcpy(self.name_storage[0..self.name_len], who[0..self.name_len]);
        self.reason_len = @intCast(@min(text.len, max_reason_len));
        @memcpy(self.reason_storage[0..self.reason_len], text[0..self.reason_len]);
        return self;
    }

    pub fn player(self: *const Request) []const u8 {
        return self.name_storage[0..self.name_len];
    }

    pub fn reasonText(self: *const Request) []const u8 {
        return self.reason_storage[0..self.reason_len];
    }

    pub fn matches(self: *const Request, who: []const u8) bool {
        return self.action == .list or std.ascii.eqlIgnoreCase(who, self.player());
    }
};

/// Workers count what they found and the last one wakes the console.
pub const Reply = struct {
    pending: std.atomic.Value(u32) = .init(0),
    found: std.atomic.Value(u32) = .init(0),
    done: std.Io.Event = .unset,

    pub fn reset(self: *Reply, workers: u32) void {
        self.pending.store(workers, .release);
        self.found.store(0, .monotonic);
        self.done.reset();
    }

    pub fn finish(self: *Reply, io: std.Io, found: u32) void {
        _ = self.found.fetchAdd(found, .monotonic);
        if (self.pending.fetchSub(1, .acq_rel) == 1) self.done.set(io);
    }
};

pub fn read(io: std.Io, context: anytype, comptime run: fn (@TypeOf(context), []const u8) error{Canceled}!void) void {
    // A proxy started in the background of a shell would otherwise be stopped the moment it read its terminal
    if (builtin.os.tag != .windows) {
        const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.TTIN, &ignore, null);
    }
    var buffer: [512]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = reader.interface.discardDelimiterInclusive('\n') catch return;
                log.warn("Ignoring a console line longer than {d} bytes", .{buffer.len});
                continue;
            },
            error.ReadFailed => {
                if (reader.err) |cause| if (cause != error.Canceled) log.debug("Console input stopped: {t}", .{cause});
                return;
            },
        } orelse return;
        run(context, std.mem.trim(u8, line, " \t\r")) catch return;
    }
}

test "commands parse with their arguments" {
    try std.testing.expectEqual(@as(?Command, null), try parse("   "));
    try std.testing.expectEqual(Command.status, (try parse("status")).?);
    try std.testing.expectEqual(Command.players, (try parse("list")).?);
    try std.testing.expectEqualStrings("Steve", (try parse("find Steve")).?.find);
    const send = (try parse("send Steve survival\r")).?.send;
    try std.testing.expectEqualStrings("Steve", send.player);
    try std.testing.expectEqualStrings("survival", send.backend);
    const kick = (try parse("kick Steve  breaking the rules ")).?.kick;
    try std.testing.expectEqualStrings("Steve", kick.player);
    try std.testing.expectEqualStrings("breaking the rules", kick.reason);
    try std.testing.expectEqualStrings("", (try parse("kick Steve")).?.kick.reason);
    try std.testing.expectEqualStrings("kick", (try parse("kick kick")).?.kick.player);
    try std.testing.expectEqual(Log.Level.debug, (try parse("log debug")).?.log);
    try std.testing.expectEqualStrings("lobby", (try parse("drain lobby")).?.drain);
}

test "names may hold spaces" {
    try std.testing.expectEqualStrings("Some Player", (try parse("find Some Player")).?.find);
    try std.testing.expectEqualStrings("Some Player", (try parse("find \"Some Player\"")).?.find);
    const send = (try parse("send Some Player survival")).?.send;
    try std.testing.expectEqualStrings("Some Player", send.player);
    try std.testing.expectEqualStrings("survival", send.backend);
    const kick = (try parse("kick \"Some Player\" no spam")).?.kick;
    try std.testing.expectEqualStrings("Some Player", kick.player);
    try std.testing.expectEqualStrings("no spam", kick.reason);
}

test "bad commands say why" {
    try std.testing.expectError(error.UnknownCommand, parse("teleport Steve"));
    try std.testing.expectError(error.Usage, parse("send Steve"));
    try std.testing.expectError(error.Usage, parse("find"));
    try std.testing.expectError(error.Usage, parse("drain lobby survival"));
    try std.testing.expectError(error.Usage, parse("kick \"Unclosed"));
    try std.testing.expectError(error.Usage, parse("kick \"\""));
    try std.testing.expectError(error.Usage, parse("log loud"));
    try std.testing.expectError(error.Usage, parse("kick " ++ &@as([max_name_len + 1]u8, @splat('x'))));
}

test "a request matches names without case and lists everyone" {
    var reply: Reply = .{};
    const find: Request = .init(.find, "steve", "", &reply);
    try std.testing.expect(find.matches("Steve"));
    try std.testing.expect(!find.matches("Alex"));
    const list: Request = .init(.list, "", "", &reply);
    try std.testing.expect(list.matches("Alex"));
    reply.reset(2);
    reply.finish(std.testing.io, 1);
    try std.testing.expect(!reply.done.isSet());
    reply.finish(std.testing.io, 2);
    try std.testing.expect(reply.done.isSet());
    try std.testing.expectEqual(@as(u32, 3), reply.found.load(.monotonic));
}
