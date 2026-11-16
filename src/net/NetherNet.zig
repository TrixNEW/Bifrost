const std = @import("std");
const nethernet = @import("nethernet");
const Keys = @import("../protocol/Keys.zig");

const NetherNet = @This();

pub const Connection = nethernet.Connection;
pub const KeyPair = nethernet.IdentityKeyPair;
pub const PublicKey = nethernet.identity.Scheme.PublicKey;
pub const Message = nethernet.Message;

// Bedwire's managed frame limit, also plenty for passthrough
pub const max_message_bytes = 2 * 1024 * 1024;
// Above this a peer counts as backed up and nothing more is read for it
pub const backlog_bytes = 1024 * 1024;

pub const Settings = struct {
    identity: KeyPair,
    // Managed mode dials with the key that signs its Logins, so backends trust one key for both
    dial_identity: ?KeyPair = null,
    // Microsoft's keys, so clients must prove the key their Login uses
    issuer_keys: ?*Keys = null,
    connect_timeout_ms: u32 = 5_000,
    port_min: u16 = 0,
    port_max: u16 = 0,
    ice_bind: ?[]const u8 = null,
    ice_servers: []const []const u8 = &.{},
    udp_mux: bool = false,
};

pub const max_ice_servers = 4;
// What players get for ICE, DTLS and SCTP after the answer. Vanilla clients allow 15 s, relayed paths can be slow
pub const ice_timeout_ms = 10_000;
// Backends check the token's age against its 60 s life, so reuse stays well under that
const token_reuse_s = 20;

const Token = struct {
    mutex: std.Io.Mutex = .init,
    text: []u8 = &.{},
    issued: i64 = 0,
};

gpa: std.mem.Allocator,
io: std.Io,
identity: KeyPair,
dial_identity: KeyPair,
issuer: ?*Keys,
native: @FieldType(nethernet.ConnectionOptions, "native"),
connect_timeout_ms: u32,
token: *Token,
// libdatachannel reads these on every new peer, so they live as long as the transport
ice_bind: [64:0]u8 = @splat(0),
ice_urls: [max_ice_servers][256:0]u8 = @splat(@splat(0)),
ice_servers: [max_ice_servers][*:0]const u8 = undefined,

/// Keep the transport where it is afterwards, peers point into it.
pub fn init(self: *NetherNet, gpa: std.mem.Allocator, io: std.Io, settings: Settings) !void {
    if (settings.ice_servers.len > max_ice_servers) return error.TooManyIceServers;
    const token = try gpa.create(Token);
    token.* = .{};
    self.* = .{
        .gpa = gpa,
        .io = io,
        .identity = settings.identity,
        .dial_identity = settings.dial_identity orelse settings.identity,
        .issuer = settings.issuer_keys,
        .native = .{
            .maximum_message_size = max_message_bytes,
            // The ring touches every page as it wraps, so this is most of a connection's resident memory
            .queue_bytes = 512 * 1024,
            // A reliable send never fails for space as long as callers stop at backlog_bytes
            .maximum_buffered_send = backlog_bytes + max_message_bytes + nethernet.framing.maximum_segments,
            .buffered_amount_low_threshold = backlog_bytes / 2,
            .port_range_begin = settings.port_min,
            .port_range_end = settings.port_max,
            .enable_ice_udp_mux = settings.udp_mux,
        },
        .connect_timeout_ms = settings.connect_timeout_ms,
        .token = token,
    };
    errdefer self.deinit();
    if (settings.ice_bind) |address| {
        if (address.len >= self.ice_bind.len) return error.InvalidIceBind;
        @memcpy(self.ice_bind[0..address.len], address);
        self.native.bind_address = self.ice_bind[0..address.len :0];
    }
    for (settings.ice_servers, 0..) |url, i| {
        if (url.len >= self.ice_urls[i].len) return error.InvalidIceServer;
        @memcpy(self.ice_urls[i][0..url.len], url);
        self.ice_servers[i] = &self.ice_urls[i];
    }
    self.native.ice_servers = self.ice_servers[0..settings.ice_servers.len];
}

pub fn deinit(self: *NetherNet) void {
    self.gpa.free(self.token.text);
    self.gpa.destroy(self.token);
}

pub fn serverOptions(self: *NetherNet) nethernet.ConnectionOptions {
    return .{
        .native = self.native,
        .maximum_message_size = max_message_bytes,
        .connection_timeout_ms = ice_timeout_ms,
        .server_identity_key = self.identity,
        .allow_anonymous = self.issuer == null,
        .verify_client = if (self.issuer != null) .{ .context = self, .verify = verify } else null,
    };
}

fn verify(context: ?*anyopaque, token: []const u8) anyerror!?nethernet.sdp_identity.Key {
    const self: *NetherNet = @ptrCast(@alignCast(context.?));
    const issuer = self.issuer.?;
    const keys = issuer.acquire();
    defer issuer.release(keys);
    return keys.signaling.verify(self.gpa, token, std.Io.Clock.real.now(self.io).toSeconds()) catch |err| {
        if (err == error.UnknownSigningKey) issuer.markStale();
        return err;
    };
}

// Backends see the proxy's own key, so they can pin it
pub fn dial(self: *const NetherNet, address: std.Io.net.IpAddress) !*Connection {
    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://{f}", .{address});
    const token = try self.dialToken(std.Io.Clock.real.now(self.io).toSeconds());
    defer self.gpa.free(token);
    var id: [8]u8 = undefined;
    self.io.random(&id);
    return nethernet.dialEndpoint(self.gpa, self.io, origin, std.mem.readInt(u64, &id, .little), .{
        .native = self.native,
        .maximum_message_size = max_message_bytes,
        .negotiation_timeout_ms = self.connect_timeout_ms,
        .connection_timeout_ms = self.connect_timeout_ms,
        .allow_anonymous = true,
        .identity = .{ .key = self.dial_identity, .token = token, .domain = "bifrost" },
    });
}

// One P-384 signature per dial otherwise, and dials run on several tasks at once
fn dialToken(self: *const NetherNet, now: i64) ![]u8 {
    const cache = self.token;
    cache.mutex.lockUncancelable(self.io);
    defer cache.mutex.unlock(self.io);
    if (cache.text.len == 0 or now < cache.issued or now - cache.issued >= token_reuse_s) {
        const fresh = try nethernet.identity.serverToken(self.gpa, self.dial_identity, now);
        self.gpa.free(cache.text);
        cache.text = fresh;
        cache.issued = now;
    }
    return self.gpa.dupe(u8, cache.text);
}

pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "signaling refused, nothing listens on that port",
        error.NoAnswer => "signaling got no answer in time",
        error.HttpFailure, error.ServiceUnavailable, error.MissingAnswer, error.RemoteFailure, error.MalformedSignal, error.UnexpectedSignal, error.UnexpectedMessage, error.MalformedSdp, error.InvalidNetworkId => "signaling failed",
        error.Unauthorized, error.Forbidden, error.AuthenticationFailed, error.InvalidIdentity, error.IdentityNotAllowed, error.UntrustedIssuer, error.ExpiredIdentity, error.SignatureVerificationFailed, error.UnknownSigningKey => "the backend rejected the proxy's identity",
        error.IceConnectFailed, error.NoLocalIceCandidate => "ICE found no working UDP path, check firewalls and the UDP port range",
        error.Timeout => "ICE or DTLS timed out after signaling",
        error.ConnectionClosed, error.ConnectionResetByPeer => "closed during setup",
        error.NetworkUnreachable, error.HostUnreachable, error.NetworkDown => "network unreachable",
        error.AddressInUse, error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "out of local sockets or ports",
        error.WebRtcFailure => "WebRTC failed",
        error.OutOfMemory => "out of memory",
        else => "connection failed",
    };
}

/// The UDP address ICE settled on, if libdatachannel can tell.
pub fn remoteAddress(connection: *Connection) ?std.Io.net.IpAddress {
    var local: [128]u8 = undefined;
    var remote: [128]u8 = undefined;
    const pair = (connection.selectedIceAddresses(&local, &remote) catch return null) orelse return null;
    return parseCandidateAddress(pair.remote);
}

fn parseCandidateAddress(text: []const u8) ?std.Io.net.IpAddress {
    return std.Io.net.IpAddress.parseLiteral(text) catch {
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
        const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
        const host = std.mem.trimEnd(u8, std.mem.trimStart(u8, text[0..colon], "["), "]");
        return std.Io.net.IpAddress.parse(host, port) catch null;
    };
}

test "dial failures name their stage" {
    try std.testing.expectEqualStrings("signaling got no answer in time", describe(error.NoAnswer));
    try std.testing.expect(std.mem.startsWith(u8, describe(error.IceConnectFailed), "ICE"));
    try std.testing.expectEqualStrings("connection failed", describe(error.SomethingElse));
}

test "candidate addresses parse with or without brackets" {
    const v4 = parseCandidateAddress("203.0.113.7:19132").?;
    try std.testing.expectEqual(@as(u16, 19132), v4.getPort());
    try std.testing.expectEqual(@as(u16, 5), parseCandidateAddress("[2001:db8::1]:5").?.getPort());
    try std.testing.expect(parseCandidateAddress("nonsense") == null);
    try std.testing.expect(parseCandidateAddress("1.2.3.4:99999") == null);
}
