const std = @import("std");
const bedwire = @import("bedwire");
const bifrost = @import("bifrost");
const protocol = @import("bedrock_protocol");
const fixtures = @import("../support/fixtures.zig");
const managed = @import("../support/managed.zig");
const sample = @import("../support/sample.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;
const Player = managed.Player;

const client_data =
    \\{"AnimatedImageData":[],"ArmSize":"wide","CapeData":"","CapeId":"","CapeImageHeight":0,
    \\"CapeImageWidth":0,"CapeOnClassicSkin":false,"ClientEditorConnectionIntent":0,
    \\"ClientIsEditorCapable":false,"ClientRandomId":1,"CompatibleWithClientSideChunkGen":false,
    \\"CurrentInputMode":1,"DefaultInputMode":1,"DeviceId":"integration","DeviceModel":"integration",
    \\"DeviceOS":7,"FilterProfanity":false,"GameVersion":"1.26.60","GraphicsMode":0,"GuiScale":0,
    \\"LanguageCode":"en_US","MaxViewDistance":8,"MemoryTier":0,"PersonaPieces":[],"PersonaSkin":false,
    \\"PieceTintColors":[],"PlatformOfflineId":"","PlatformOnlineId":"","PlatformType":0,
    \\"PremiumSkin":false,"ProfileHash":"","SelfSignedId":"00000000-0000-4000-8000-000000000001",
    \\"ServerAddress":"proxy","SkinAnimationData":"","SkinColor":"#000000","SkinGeometryData":"",
    \\"SkinGeometryDataEngineVersion":"","SkinId":"interop","SkinImageHeight":64,"SkinImageWidth":64,
    \\"SkinResourcePatch":"eyJnZW9tZXRyeSI6eyJkZWZhdWx0IjoiZ2VvbWV0cnkuaHVtYW5vaWQuY3VzdG9tIn19",
    \\"ThirdPartyName":"Steve","TrustedSkin":true,"UIProfile":0,"SkinData":
++ "\"" ++ @as([21844]u8, @splat('A')) ++ "AA==\"}";

test "Quark proxy-only backends support managed join, gameplay, transfer and reconnect" {
    const addresses = @import("test_options").quark_backends orelse return error.SkipZigTest;
    const proxy_key = try bifrost.loadProxyKey(io, @import("test_options").quark_proxy_key orelse return error.MissingQuarkProxyKey);
    var parts = std.mem.splitScalar(u8, addresses, ',');
    const address_a = try std.Io.net.IpAddress.parseLiteral(parts.next() orelse return error.MissingQuarkAddress);
    const address_b = try std.Io.net.IpAddress.parseLiteral(parts.next() orelse return error.MissingQuarkAddress);
    if (parts.next() != null) return error.TooManyQuarkAddresses;

    try std.testing.expectError(error.Forbidden, fixtures.Player.connect(io, address_a));

    var keys = try managed.keySet();
    defer keys.deinit();
    var config = try managed.config(&.{ address_a, address_b });
    config.private_backend_ice = true;
    try config.setIceBind("127.0.0.1");
    config.transfer_phase_timeout_ms = 15_000;
    config.transfer_timeout_ms = 30_000;
    var running: fixtures.Running = undefined;
    try running.start(io, config, .{ .auth = .{ .verify = &keys }, .proxy_key = proxy_key });
    defer running.deinit();

    {
        const player = try Player.connectWithLimits(io, running.address(), 2, bifrost.Managed.limits);
        defer player.destroy();
        try join(player);
        try gameplay(player, 5);
        try running.proxy.requestTransfer(1, .of(1));
        const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(30));
        player.timeout_ms = 100;
        while (running.proxy.stats.snapshot().transfers_committed == 0 or player.changes.items.len == 0) {
            if (std.Io.Clock.awake.now(io).durationTo(deadline).nanoseconds <= 0) return error.QuarkTransferTimedOut;
            player.pump() catch |err| if (err != error.NoMessage) return err;
        }
        player.timeout_ms = 5_000;
        try gameplay(player, 4);
    }
    try running.waitForStat(.links_closed, 1);

    const player = try Player.connectWithLimits(io, running.address(), 2, bifrost.Managed.limits);
    defer player.destroy();
    try join(player);
    try gameplay(player, 5);
}

fn join(player: *Player) !void {
    try player.settings(@intCast(protocol.protocol_version));
    const now = std.Io.Clock.real.now(io).toSeconds();
    const request = try sample.requestWithClientData(gpa, player.key, player.key, "Steve", "2535400000000001", now, client_data);
    defer gpa.free(request);
    const storage = try gpa.alloc(u8, request.len + 32);
    defer gpa.free(storage);
    try player.send(&.{try bedwire.auth.login.encodeLoginPacket(protocol.protocol_version, storage, request, .{})});
    _ = try waitFor(player, .resource_packs_info);

    var buffer: [32]u8 = undefined;
    try player.send(&.{try sample.typedPacket(&buffer, .{ .resource_pack_client_response = .{ .response = .{ .downloading_finished = "downloadingfinished" } } })});
    _ = try waitFor(player, .resource_pack_stack);
    try player.send(&.{try sample.typedPacket(&buffer, .{ .resource_pack_client_response = .{ .response = .{ .resource_pack_stack_finished = "resourcepackstackfinished" } } })});
    try player.session.advance(.waiting_for_start_game);
    const start = try waitFor(player, .start_game);
    player.runtime_id = start.runtime_id;
    try player.session.advance(.spawn_ready);
    try requestRadius(player, 6);
    while ((try waitFor(player, .play_status)).status != .playerspawn) {}
    try player.send(&.{try sample.typedPacket(&buffer, .{ .set_local_player_as_initialised = .{ .player_id = player.runtime_id } })});
    try player.session.advance(.in_game);
}

fn gameplay(player: *Player, radius: i32) !void {
    try requestRadius(player, radius);
    while ((try waitFor(player, .chunk_radius_updated)).chunk_radius != radius) {}
}

fn requestRadius(player: *Player, radius: i32) !void {
    var buffer: [16]u8 = undefined;
    try player.send(&.{try sample.typedPacket(&buffer, .{ .request_chunk_radius = .{ .chunk_radius = radius, .max_chunk_radius = 12 } })});
}

fn waitFor(player: *Player, comptime kind: protocol.PacketKind) !@FieldType(protocol.typed.Packet, @tagName(kind)) {
    for (0..512) |_| {
        var packets = try player.receive();
        defer packets.deinit();
        while (packets.next()) |packet| {
            if (packet.kind == .disconnect) return error.QuarkDisconnected;
            if (protocol.registry.packetKind(packet.id) == kind) {
                const decoded = try protocol.typed.decode(packet.bytes, .{});
                return @field(decoded.packet, @tagName(kind));
            }
        }
    }
    return error.QuarkPacketNotReceived;
}
