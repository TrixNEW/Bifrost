const std = @import("std");
const clock = @import("../clock.zig");

const log = @import("../log.zig").scoped(.network);

const request_timeout_ms = 2_000;
const max_request = 2048;

pub const Histogram = struct {
    // Bucket i holds samples up to 2^i microseconds, the last one everything slower
    pub const buckets = 24;

    counts: [buckets]u64 = @splat(0),
    sum_us: u64 = 0,

    // One writer per histogram, so plain atomic stores are enough
    pub fn record(self: *Histogram, us: u64) void {
        const index = @min(std.math.log2_int_ceil(u64, @max(us, 1)), buckets - 1);
        bump(&self.counts[index], 1);
        bump(&self.sum_us, us);
    }

    pub fn add(self: *Histogram, other: *const Histogram) void {
        for (&self.counts, &other.counts) |*total, *count| total.* += @atomicLoad(u64, count, .monotonic);
        self.sum_us +%= @atomicLoad(u64, &other.sum_us, .monotonic);
    }

    fn bump(counter: *u64, amount: u64) void {
        @atomicStore(u64, counter, counter.* +% amount, .monotonic);
    }
};

pub const Timings = struct {
    turn: Histogram = .{},
    dial: Histogram = .{},
    transfer: Histogram = .{},

    pub fn add(self: *Timings, other: *const Timings) void {
        inline for (@typeInfo(Timings).@"struct".field_names) |name| @field(self, name).add(&@field(other, name));
    }
};

pub fn sinceUs(io: std.Io, started_ns: u64) u64 {
    return (clock.ns(io) -| started_ns) / std.time.ns_per_us;
}

pub fn header(w: *std.Io.Writer, name: []const u8, kind: []const u8, help: []const u8) !void {
    try w.print("# HELP bifrost_{s} {s}\n# TYPE bifrost_{s} {s}\n", .{ name, help, name, kind });
}

pub fn value(w: *std.Io.Writer, name: []const u8, kind: []const u8, help: []const u8, amount: anytype) !void {
    try header(w, name, kind, help);
    try w.print("bifrost_{s} {d}\n", .{ name, amount });
}

pub fn histogram(w: *std.Io.Writer, name: []const u8, help: []const u8, h: *const Histogram) !void {
    try header(w, name, "histogram", help);
    var cumulative: u64 = 0;
    for (h.counts[0 .. Histogram.buckets - 1], 0..) |count, i| {
        cumulative += count;
        const bound = @as(f64, @floatFromInt(@as(u64, 1) << @intCast(i))) / std.time.us_per_s;
        try w.print("bifrost_{s}_bucket{{le=\"{d}\"}} {d}\n", .{ name, bound, cumulative });
    }
    cumulative += h.counts[Histogram.buckets - 1];
    try w.print("bifrost_{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ name, cumulative });
    try w.print("bifrost_{s}_sum {d}\n", .{ name, @as(f64, @floatFromInt(h.sum_us)) / std.time.us_per_s });
    try w.print("bifrost_{s}_count {d}\n", .{ name, cumulative });
}

/// Answers `GET /metrics` with what `source.writeMetrics` prints, until canceled.
pub fn serve(io: std.Io, gpa: std.mem.Allocator, server: *std.Io.net.Server, source: anytype) void {
    log.info("Metrics on http://{f}/metrics", .{server.socket.address});
    if (!isLoopback(server.socket.address)) log.warn("Metrics have no authentication and listen beyond this machine; firewall {f}", .{server.socket.address});
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                log.warn("Metrics listener can't accept: {t}", .{err});
                io.sleep(.fromMilliseconds(100), .awake) catch return;
                continue;
            },
        };
        defer stream.close(io);
        answer(io, gpa, stream, source) catch |err| switch (err) {
            error.Canceled => return,
            else => log.debug("Metrics request failed: {t}", .{err}),
        };
    }
}

fn isLoopback(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip| ip.bytes[0] == 127,
        .ip6 => |ip| std.mem.eql(u8, &ip.bytes, &(@as([15]u8, @splat(0)) ++ [_]u8{1})),
    };
}

// One client at a time with one deadline for the whole exchange, so a stuck or trickling scraper can't hold it
fn answer(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream, source: anytype) !void {
    const timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(request_timeout_ms), .clock = .awake } }).toDeadline(io);
    var request: [max_request]u8 = undefined;
    var len: usize = 0;
    while (std.mem.indexOf(u8, request[0..len], "\r\n\r\n") == null) {
        if (len == request.len) return error.RequestTooLarge;
        var data = [_][]u8{request[len..]};
        const read = try (try operate(io, .{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } }, timeout)).net_read;
        if (read.data_len == 0) return error.EndOfStream;
        len += read.data_len;
    }
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const found = std.mem.startsWith(u8, request[0..len], "GET /metrics ") or std.mem.startsWith(u8, request[0..len], "GET /metrics?");
    if (found) try source.writeMetrics(&body.writer) else try body.writer.writeAll("not found\n");
    var head: [160]u8 = undefined;
    const status = if (found) "200 OK" else "404 Not Found";
    const response = try std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.written().len });
    for ([_][]const u8{ response, body.written() }) |part| {
        var rest = part;
        while (rest.len != 0) {
            const wrote = try (try operate(io, .{ .net_write = .{ .socket_handle = stream.socket.handle, .data = &.{rest} } }, timeout)).net_write;
            rest = rest[wrote..];
        }
    }
    stream.shutdown(io, .send) catch {};
}

// ZIO has timeouts, the threaded test Io doesn't and refuses before starting the operation
fn operate(io: std.Io, operation: std.Io.Operation, timeout: std.Io.Timeout) !std.Io.Operation.Result {
    return io.operateTimeout(operation, timeout) catch |err| switch (err) {
        error.ConcurrencyUnavailable => io.operate(operation),
        else => err,
    };
}

pub fn label(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(byte),
    };
}

test "histogram buckets are cumulative and end in +Inf" {
    var h: Histogram = .{};
    h.record(0);
    h.record(1);
    h.record(3);
    h.record(std.math.maxInt(u64) / 2);
    try std.testing.expectEqual(@as(u64, 2), h.counts[0]);
    try std.testing.expectEqual(@as(u64, 1), h.counts[2]);
    try std.testing.expectEqual(@as(u64, 1), h.counts[Histogram.buckets - 1]);

    var total: Histogram = .{};
    total.add(&h);
    total.add(&h);
    var buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try histogram(&w, "test_seconds", "Test.", &total);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "bifrost_test_seconds_bucket{le=\"0.000001\"} 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bifrost_test_seconds_bucket{le=\"0.000004\"} 6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bifrost_test_seconds_bucket{le=\"+Inf\"} 8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bifrost_test_seconds_count 8\n") != null);

    w = .fixed(&buffer);
    try label(&w, "a\"b\\c\nd");
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd", w.buffered());
}
