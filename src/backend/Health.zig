const std = @import("std");
const Config = @import("../config/Config.zig");
const Backend = @import("Backend.zig");

const Health = @This();
const log = @import("../log.zig").scoped(.backend);

pub const Status = enum(u8) { unknown, healthy, unhealthy };

const Entry = struct {
    status: std.atomic.Value(Status) = .init(.unknown),
    players: std.atomic.Value(u32) = .init(0),
    // Only probes say a backend is down or back, so a dial failure between passing probes doesn't flap
    probe_failed: std.atomic.Value(bool) = .init(false),
    dial_warned_ms: std.atomic.Value(u64) = .init(0),
    // This proxy's players there, counting transfers on their way in
    proxied: std.atomic.Value(u32) = .init(0),
    draining: std.atomic.Value(bool) = .init(false),
};

const dial_warning_interval_ms = 60_000;

backends: []const Backend,
interval_ms: u32,
timeout_ms: u32,
entries: [Config.max_backends]Entry = @splat(.{}),
recheck: std.Io.Event = .unset,

pub fn init(backends: []const Backend, interval_ms: u32, timeout_ms: u32) Health {
    var self: Health = .{ .backends = backends, .interval_ms = interval_ms, .timeout_ms = timeout_ms };
    for (backends, self.entries[0..backends.len]) |backend, *entry| entry.draining.raw = backend.draining;
    return self;
}

pub fn status(self: *const Health, id: Backend.Id) Status {
    return self.entries[id.index()].status.load(.acquire);
}

pub fn claim(self: *Health, id: Backend.Id) bool {
    const entry = &self.entries[id.index()];
    const limit = self.backends[id.index()].max_players;
    if (limit == 0) {
        _ = entry.proxied.fetchAdd(1, .monotonic);
        return true;
    }
    var current = entry.proxied.load(.monotonic);
    while (current < limit) current = entry.proxied.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) orelse return true;
    return false;
}

pub fn release(self: *Health, id: Backend.Id) void {
    const previous = self.entries[id.index()].proxied.fetchSub(1, .monotonic);
    std.debug.assert(previous != 0);
}

pub fn proxied(self: *const Health, id: Backend.Id) u32 {
    return self.entries[id.index()].proxied.load(.monotonic);
}

pub fn isDraining(self: *const Health, id: Backend.Id) bool {
    return self.entries[id.index()].draining.load(.acquire);
}

pub fn setDraining(self: *Health, id: Backend.Id, draining: bool) bool {
    return self.entries[id.index()].draining.swap(draining, .acq_rel) != draining;
}

pub fn markFailed(self: *Health, id: Backend.Id) void {
    self.entries[id.index()].status.store(.unhealthy, .release);
}

/// Whether a failed dial should be a warning: once a minute per backend, the rest are debug.
pub fn warnDial(self: *Health, id: Backend.Id, now_ms: u64) bool {
    const last = &self.entries[id.index()].dial_warned_ms;
    const previous = last.load(.monotonic);
    if (previous != 0 and now_ms -| previous < dial_warning_interval_ms) return false;
    return last.cmpxchgStrong(previous, @max(now_ms, 1), .monotonic, .monotonic) == null;
}

pub fn healthyCount(self: *const Health) usize {
    var count: usize = 0;
    for (self.entries[0..self.backends.len]) |*entry| count += @intFromBool(entry.status.load(.acquire) == .healthy);
    return count;
}

pub fn onlinePlayers(self: *const Health) u32 {
    var total: u32 = 0;
    for (self.entries[0..self.backends.len]) |*entry| {
        if (entry.status.load(.acquire) == .healthy) total +|= entry.players.load(.monotonic);
    }
    return total;
}

pub fn run(self: *Health, io: std.Io) void {
    while (true) {
        self.checkAll(io) catch return;
        self.recheck.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(self.interval_ms), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return,
        };
        self.recheck.reset();
    }
}

pub fn checkAll(self: *Health, io: std.Io) error{Canceled}!void {
    var group: std.Io.Group = .init;
    for (0..self.backends.len) |index| {
        group.concurrent(io, check, .{ self, io, index }) catch check(self, io, index);
    }
    try group.await(io);
}

fn check(self: *Health, io: std.Io, index: usize) void {
    const backend = &self.backends[index];
    const entry = &self.entries[index];
    const players_now = probe(io, backend.address, self.timeout_ms) catch |err| {
        if (err == error.Canceled) return;
        entry.status.store(.unhealthy, .release);
        if (!entry.probe_failed.swap(true, .monotonic))
            log.warn("{f} is down: {s} ({t})", .{ backend.*, probeFailure(err), err })
        else
            log.debug("{f} still down: {t}", .{ backend.*, err });
        return;
    };
    entry.players.store(players_now, .monotonic);
    const was = entry.status.swap(.healthy, .acq_rel);
    if (entry.probe_failed.swap(false, .monotonic))
        log.info("{f} is back up ({d} online)", .{ backend.*, players_now })
    else if (was == .unknown)
        log.info("{f} is up ({d} online)", .{ backend.*, players_now })
    else if (was == .unhealthy)
        log.debug("{f} answers status queries again after a failed dial", .{backend.*});
}

fn probeFailure(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "nothing is listening on its signaling port",
        error.Timeout => "its status query got no answer in time",
        error.BackendUnavailable => "it answered the status query with an error",
        error.InvalidStatus => "its status response was incomplete or invalid",
        error.NetworkUnreachable, error.HostUnreachable => "its address is unreachable",
        error.ConnectionResetByPeer, error.EndOfStream => "it closed the status query",
        else => "its status query failed",
    };
}

/// Asks the backend's signaling endpoint for its status, the same query the game's server list makes.
pub fn probe(io: std.Io, address: std.Io.net.IpAddress, timeout_ms: u32) !u32 {
    const Result = union(enum) { players: anyerror!u32, timeout: std.Io.Cancelable!void };
    var results: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.timeout, std.Io.sleep, .{ io, std.Io.Duration.fromMilliseconds(timeout_ms), .awake });
    try select.concurrent(.players, query, .{ io, address });
    return switch (try select.await()) {
        .players => |players| players,
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    };
}

fn query(io: std.Io, address: std.Io.net.IpAddress) anyerror!u32 {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var send_buffer: [128]u8 = undefined;
    var sender = stream.writer(io, &send_buffer);
    sender.interface.print("GET /v1/join HTTP/1.1\r\nHost: {f}\r\nConnection: close\r\n\r\n", .{address}) catch return sender.err orelse error.WriteFailed;
    sender.interface.flush() catch return sender.err orelse error.WriteFailed;

    var receive_buffer: [8 * 1024]u8 = undefined;
    var receiver = stream.reader(io, &receive_buffer);
    var http: std.http.Reader = .{ .in = &receiver.interface, .interface = undefined, .state = .ready, .max_head_len = receive_buffer.len };
    const head = try std.http.Client.Response.Head.parse(http.receiveHead() catch |err| return if (err == error.ReadFailed) receiver.err orelse err else err);
    if (head.status != .ok) return error.BackendUnavailable;
    var transfer: [1024]u8 = undefined;
    var body_buffer: [16 * 1024]u8 = undefined;
    const length = if (head.transfer_encoding == .none) head.content_length else null;
    if ((length orelse 0) > body_buffer.len) return error.InvalidStatus;
    var body = std.Io.Writer.fixed(&body_buffer);
    const received = http.bodyReader(&transfer, head.transfer_encoding, length).streamRemaining(&body) catch |err|
        return if (err == error.ReadFailed) receiver.err orelse error.InvalidStatus else error.InvalidStatus;
    if (length) |expected| if (received != expected) return error.InvalidStatus;
    return playerCount(body.buffered());
}

// An empty 200 is a valid answer too, it just has no count
fn playerCount(json: []const u8) u32 {
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const Body = struct { players: u32 = 0 };
    const parsed = std.json.parseFromSliceLeaky(Body, fixed.allocator(), json, .{ .ignore_unknown_fields = true }) catch return 0;
    return parsed.players;
}

test "status bodies give a player count or nothing" {
    try std.testing.expectEqual(@as(u32, 7), playerCount("{\"name\":\"x\",\"players\":7,\"maxPlayers\":10}"));
    try std.testing.expectEqual(@as(u32, 0), playerCount(""));
    try std.testing.expectEqual(@as(u32, 0), playerCount("{\"players\":-1}"));
}

test "backend health rejects a truncated status response" {
    const io = std.testing.io;
    const Address = std.Io.net.IpAddress;
    var listener = try (Address{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    const Response = struct {
        fn send(server: *std.Io.net.Server) !void {
            const stream = try server.accept(io);
            defer stream.close(io);
            var input: [256]u8 = undefined;
            var output: [128]u8 = undefined;
            var reader = stream.reader(io, &input);
            var writer = stream.writer(io, &output);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            _ = try http.receiveHead();
            try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\n{\"players\":7}");
            try writer.interface.flush();
        }
    };
    var task = try io.concurrent(Response.send, .{&listener});
    defer task.cancel(io) catch {};
    try std.testing.expectError(error.InvalidStatus, probe(io, listener.socket.address, 2_000));
    try task.await(io);
}

test "online players sum healthy backends and saturate" {
    var backends: [3]Backend = undefined;
    for (&backends, 1..) |*backend, port| backend.* = try .init(null, .{ .ip4 = .loopback(@intCast(port)) });
    var health: Health = .init(&backends, 1000, 100);
    try std.testing.expectEqual(@as(u32, 0), health.onlinePlayers());

    health.entries[0].status.store(.healthy, .release);
    health.entries[0].players.store(std.math.maxInt(u32) - 1, .monotonic);
    health.entries[1].status.store(.healthy, .release);
    health.entries[1].players.store(5, .monotonic);
    health.entries[2].status.store(.unhealthy, .release);
    health.entries[2].players.store(1000, .monotonic);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), health.onlinePlayers());
    try std.testing.expectEqual(@as(usize, 2), health.healthyCount());

    health.markFailed(.of(0));
    try std.testing.expectEqual(Status.unhealthy, health.status(.of(0)));
    try std.testing.expectEqual(@as(u32, 5), health.onlinePlayers());
}

test "failed dials warn once a minute per backend" {
    var backends: [2]Backend = undefined;
    for (&backends, 1..) |*backend, port| backend.* = try .init(null, .{ .ip4 = .loopback(@intCast(port)) });
    var health: Health = .init(&backends, 1000, 100);
    try std.testing.expect(health.warnDial(.of(0), 0));
    try std.testing.expect(!health.warnDial(.of(0), 59_999));
    try std.testing.expect(health.warnDial(.of(1), 59_999));
    try std.testing.expect(health.warnDial(.of(0), 60_001));
    try std.testing.expect(!health.warnDial(.of(0), 60_002));
}
