const std = @import("std");
const nethernet = @import("nethernet");
const NetherNet = @import("NetherNet.zig");

/// Answers HTTP signaling and hands every established connection to `sink`.
const Listener = @This();

pub const Sink = struct {
    context: *anyopaque,
    /// Takes ownership of the connection.
    accept: *const fn (*anyopaque, *NetherNet.Connection) void,
};

pub const Status = nethernet.EndpointStatusProvider;
pub const ServerStatus = nethernet.EndpointServerStatus;

// A Bedrock client sends its offer at once, so a slow request is someone holding a worker
pub const request_read_timeout_ms = 3_000;
pub const max_connections_per_ip = 4;

pub const Options = struct {
    max_negotiations: u32 = 32,
    max_negotiations_per_ip: u32 = 4,
    // Public addresses a NAT or port forward exposes the ICE ports on
    advertise_addresses: []const []const u8 = &.{},
    status: ?Status = null,
    // NetherNet's own signaling and negotiation diagnostics, printed unformatted
    trace: bool = false,
};

io: std.Io,
endpoint: *nethernet.EndpointListener,
sink: Sink,
task: ?std.Io.Future(void) = null,

pub fn start(gpa: std.mem.Allocator, io: std.Io, transport: *NetherNet, address: std.Io.net.IpAddress, sink: Sink, options: Options) !*Listener {
    const self = try gpa.create(Listener);
    errdefer gpa.destroy(self);
    const endpoint = try nethernet.EndpointListener.listen(gpa, io, address, .{
        .connection = transport.serverOptions(),
        .maximum_negotiations = options.max_negotiations,
        .maximum_negotiations_per_address = options.max_negotiations_per_ip,
        // Idle or slow sockets each hold a worker, so there are far more workers than one address may hold
        .maximum_http_workers = std.math.clamp(4 * options.max_negotiations, 64, 512),
        .maximum_connections_per_address = @max(max_connections_per_ip, options.max_negotiations_per_ip),
        .request_read_timeout_ms = request_read_timeout_ms,
        .request_timeout_ms = request_read_timeout_ms + NetherNet.ice_timeout_ms,
        .status_provider = options.status,
        .advertise_addresses = options.advertise_addresses,
        .trace = options.trace,
    });
    errdefer endpoint.destroy();
    self.* = .{ .io = io, .endpoint = endpoint, .sink = sink };
    self.task = try io.concurrent(run, .{self});
    return self;
}

pub fn destroy(self: *Listener, gpa: std.mem.Allocator) void {
    if (self.task) |*task| task.cancel(self.io);
    self.endpoint.destroy();
    gpa.destroy(self);
}

pub fn localAddress(self: *const Listener) std.Io.net.IpAddress {
    return self.endpoint.server.socket.address;
}

fn run(self: *Listener) void {
    while (true) {
        // Only shutdown ends this: the queue closing or the task being canceled
        const connection = self.endpoint.accept() catch return;
        self.sink.accept(self.sink.context, connection);
    }
}
