const std = @import("std");
const protocol = @import("bedrock_protocol");
const test_options = @import("test_options");
const fixtures = @import("../support/fixtures.zig");
const managed = @import("../support/managed.zig");
const FailOnce = @import("../support/FailOnce.zig");
const Rig = @import("../support/rig.zig").Rig;

const Player = managed.Player;
const Vec3f = protocol.Vec3f;
const io = std.testing.io;

const overworld = 0;
const nether = 1;
const spawn: Vec3f = .{ .x = 10, .y = 70, .z = 10 };
const far: Vec3f = .{ .x = 29_999_000, .y = 300, .z = -29_999_000 };

const Changes = struct {
    player: *Player,
    at_least: usize,

    fn reached(self: Changes) bool {
        return self.player.changes.items.len >= self.at_least;
    }
};

fn waitForChanges(rig: *Rig, at_least: usize) !void {
    try rig.pumpUntil(Changes{ .player = rig.player, .at_least = at_least }, Changes.reached);
}

fn moveTo(rig: *Rig, target: usize, round: u64) !void {
    try rig.transfer(target);
    try rig.waitFor(.transfers_committed, round);
    try rig.expectOn(if (target == 1) &rig.b else &rig.a);
}

fn expectLanded(player: *const Player, dimension: i32, position: Vec3f) !void {
    const last = player.changes.getLast();
    try std.testing.expectEqual(dimension, last.dimension_id);
    try std.testing.expectEqual(position, last.position);
}

fn pumpFor(player: *Player, ms: i64) !void {
    _ = try player.countGamePackets("", ms);
}

test "a same-dimension move detours once and lands on the target spawn" {
    for ([_]Vec3f{ spawn, far }) |position| {
        var rig: Rig = undefined;
        try rig.start(.{ .a_content = .{ .position = spawn }, .b_content = .{ .position = position } });
        defer rig.deinit();
        try moveTo(&rig, 1, 1);

        const player = rig.player;
        try std.testing.expectEqual(@as(usize, 2), player.changes.items.len);
        try std.testing.expectEqual(@as(i32, nether), player.changes.items[0].dimension_id);
        try expectLanded(player, overworld, position);
        try std.testing.expectEqual(@as(usize, 2), player.received(.level_chunk));
        try std.testing.expectEqual(@as(usize, 1), player.received(.chunk_radius_updated));
        try std.testing.expect(player.lastIndex(.level_chunk).? > player.lastIndex(.change_dimension).?);
    }
}

test "the old backend's last dimension change isn't taken for the handoff's" {
    var rig: Rig = undefined;
    try rig.start(.{ .b_content = .{ .dimension = nether, .position = far } });
    defer rig.deinit();
    rig.player.hold_acks = true;
    var buffer: [128]u8 = undefined;
    try rig.player.relay(&.{try managed.typedPacket(&buffer, .{ .change_dimension = .{ .dimension_id = nether, .position = spawn, .respawn = false, .loading_screen_id = null } })});

    try rig.transfer(1);
    // The old backend's change, then the detour to the overworld
    try waitForChanges(&rig, 2);
    rig.player.held_acks = 1;
    try rig.player.releaseAcks();
    rig.player.hold_acks = true;
    try pumpFor(rig.player, 300);
    try std.testing.expectEqual(@as(usize, 2), rig.player.changes.items.len);
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_committed);

    rig.player.held_acks = 1;
    try rig.player.releaseAcks();
    try rig.waitFor(.transfers_committed, 1);
    try std.testing.expectEqual(@as(usize, 3), rig.player.changes.items.len);
    try expectLanded(rig.player, nether, far);
}

fn backendTransfer(buffer: []u8, host: []const u8, port: u16) ![]const u8 {
    return managed.typedPacket(buffer, .{ .transfer = .{ .server_address = host, .server_port = port, .reload_world = false, .gatherings_configuration = null } });
}

test "a backend's Transfer to another listed backend becomes a proxy transfer" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    var buffer: [128]u8 = undefined;
    try rig.player.relay(&.{try backendTransfer(&buffer, "127.0.0.1", rig.b.address().getPort())});
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try std.testing.expectEqual(@as(u64, 1), rig.stats().backend_redirects);
    try std.testing.expectEqual(@as(usize, 0), rig.player.received(.transfer));
}

fn kickPacket(buffer: []u8) ![]const u8 {
    return managed.typedPacket(buffer, .{ .disconnect = .{ .reason = .disconnected, .messages = .{ .messages = .{ .message = "moving you", .filtered_message = "" } } } });
}

fn kicked(player: *Player) bool {
    return player.received(.disconnect) != 0;
}

test "a backend that sends the player on, kicks them and closes doesn't take them with it" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    var transfer: [128]u8 = undefined;
    var kick: [128]u8 = undefined;
    const packets = [_][]const u8{ try backendTransfer(&transfer, "127.0.0.1", rig.b.address().getPort()), try kickPacket(&kick) };
    // One batch asks the backend to send both and then close, so the proxy can see all of it in one turn
    var buffer: [512]u8 = undefined;
    var writer = protocol.Writer.init(&buffer);
    try writer.writeVarU32(managed.game_packet_id);
    try writer.writeRaw("relay");
    for (packets) |packet| {
        try writer.writeRaw(&std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(packet.len))));
        try writer.writeRaw(packet);
    }
    var close: [16]u8 = undefined;
    try rig.player.send(&.{ writer.written(), try managed.rawPacket(&close, managed.game_packet_id, "kick") });
    var marker: [256]u8 = undefined;
    while (!std.mem.eql(u8, try rig.player.nextGamePacket(&marker), "relayed")) {}
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try std.testing.expectEqual(@as(usize, 0), rig.player.received(.disconnect));
    try std.testing.expectEqual(@as(u64, 1), rig.stats().backend_redirects);
}

test "a player who keeps playing after the old backend's kick still moves" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    var transfer: [128]u8 = undefined;
    var kick: [128]u8 = undefined;
    // The backend stays connected, so what the player sends next would still reach it
    try rig.player.relay(&.{ try backendTransfer(&transfer, "127.0.0.1", rig.b.address().getPort()), try kickPacket(&kick) });
    var buffer: [32]u8 = undefined;
    for (0..3) |_| try rig.player.send(&.{try managed.rawPacket(&buffer, managed.game_packet_id, "still here")});
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try std.testing.expectEqual(@as(usize, 0), rig.player.received(.disconnect));
}

test "a kick held back during a move that fails still reaches the player" {
    var rig: Rig = undefined;
    try rig.start(.{ .phase_timeout_ms = 1_000 });
    defer rig.deinit();
    // The target never answers the login, so the move times out
    rig.b.hold_login.store(true, .release);
    try rig.transfer(1);
    var kick: [128]u8 = undefined;
    try rig.player.relay(&.{try kickPacket(&kick)});
    try pumpFor(rig.player, 100);
    try std.testing.expectEqual(@as(usize, 0), rig.player.received(.disconnect));
    try rig.waitFor(.transfers_timed_out, 1);
    try rig.pumpUntil(rig.player, kicked);
}

test "a backend's Transfer anywhere else is dropped" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    var buffer: [128]u8 = undefined;
    try rig.player.relay(&.{try backendTransfer(&buffer, "203.0.113.9", 19132)});
    try rig.waitFor(.redirects_blocked, 1);
    try pumpFor(rig.player, 100);
    try std.testing.expectEqual(@as(usize, 0), rig.player.received(.transfer));
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_started);
    try rig.expectOn(&rig.a);
}

test "the target's world settings reach the client, since its StartGame never does" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    try std.testing.expectEqual(@as(usize, 0), rig.player.received(.set_time));
    try moveTo(&rig, 1, 1);
    for ([_]protocol.PacketKind{ .set_time, .set_commands_enabled }) |kind| {
        try std.testing.expectEqual(@as(usize, 1), rig.player.received(kind));
    }
    try std.testing.expect(rig.player.lastIndex(.set_time).? > rig.player.lastIndex(.change_dimension).?);
}

test "moving between dimensions needs no detour either way" {
    var rig: Rig = undefined;
    try rig.start(.{ .b_content = .{ .dimension = nether, .position = far } });
    defer rig.deinit();

    try moveTo(&rig, 1, 1);
    try std.testing.expectEqual(@as(usize, 1), rig.player.changes.items.len);
    try expectLanded(rig.player, nether, far);
    try moveTo(&rig, 0, 2);
    try std.testing.expectEqual(@as(usize, 2), rig.player.changes.items.len);
    try std.testing.expectEqual(overworld, rig.player.changes.items[1].dimension_id);
    try std.testing.expectEqual(@as(usize, 2), rig.player.received(.level_chunk));
}

test "the client's cache support reaches every backend" {
    for ([_]?bool{ true, false, null }) |cache| {
        var rig: Rig = undefined;
        try rig.start(.{ .cache = cache });
        defer rig.deinit();
        try moveTo(&rig, 1, 1);

        const reports: u32 = if (cache == null) 0 else 1;
        try std.testing.expectEqual(reports, rig.a.cache_reports.load(.acquire));
        try std.testing.expectEqual(reports, rig.b.cache_reports.load(.acquire));
        if (cache) |supported| try std.testing.expectEqual(supported, rig.b.cache_supported.load(.acquire));
    }
}

test "sub-chunk requests during and after the switch go to the target" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    var buffer: [64]u8 = undefined;
    const request = try managed.typedPacket(&buffer, .{ .sub_chunk_request = .{
        .dimension_type = overworld,
        .sub_chunk_position_offset_list = .empty,
        .center_pos = .{ .x = 0, .y = 4, .z = 0 },
    } });

    rig.player.hold_acks = true;
    try rig.transfer(1);
    try waitForChanges(&rig, 1);
    try rig.player.send(&.{request});
    try fixtures.waitFor(io, &rig.b.sub_chunk_requests, 1);
    try rig.player.releaseAcks();
    try rig.waitFor(.transfers_committed, 1);
    try rig.player.send(&.{request});
    try fixtures.waitFor(io, &rig.b.sub_chunk_requests, 2);
    try std.testing.expectEqual(@as(u32, 0), rig.a.sub_chunk_requests.load(.acquire));
}

test "what the old backend showed is cleared once, before the new world" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    var buffer: [16]u8 = undefined;
    try rig.player.send(&.{try managed.rawPacket(&buffer, managed.game_packet_id, "scene")});
    const Scene = struct {
        fn shown(player: *Player) bool {
            return player.received(.mob_effect) == 1;
        }
    };
    try rig.pumpUntil(rig.player, Scene.shown);
    try std.testing.expectEqual(@as(usize, managed.Backend.scene_entities), rig.player.received(.add_painting));

    try moveTo(&rig, 1, 1);
    const player = rig.player;
    try std.testing.expectEqual(@as(usize, managed.Backend.scene_entities), player.received(.remove_actor));
    try std.testing.expectEqual(@as(usize, 1), player.received(.container_close));
    try std.testing.expectEqual(@as(usize, 1), player.received(.remove_objective));
    try std.testing.expectEqual(@as(usize, 2), player.received(.boss_event));
    try std.testing.expectEqual(@as(usize, 2), player.received(.mob_effect));
    const first_change = std.mem.indexOfScalar(protocol.PacketKind, player.kinds.items, .change_dimension).?;
    try std.testing.expect(player.lastIndex(.remove_actor).? < first_change);

    try moveTo(&rig, 0, 2);
    try std.testing.expectEqual(@as(usize, managed.Backend.scene_entities), player.received(.remove_actor));
    try std.testing.expectEqual(@as(usize, 1), player.received(.container_close));
}

test "a client ack before the target spawns waits for the spawn" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    rig.b.hold_spawn.store(true, .release);

    try rig.transfer(1);
    try waitForChanges(&rig, 2);
    try fixtures.waitFor(io, &rig.b.chunk_requests, 1);
    try pumpFor(rig.player, 200);
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_committed);
    try std.testing.expectEqual(@as(u32, 0), rig.b.spawns.load(.acquire));

    rig.b.hold_spawn.store(false, .release);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try std.testing.expectEqual(@as(u32, 1), rig.b.spawns.load(.acquire));
}

test "a target spawn before the client acks waits for the ack" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    rig.player.hold_acks = true;

    try rig.transfer(1);
    try waitForChanges(&rig, 1);
    try fixtures.waitFor(io, &rig.b.chunk_requests, 1);
    try pumpFor(rig.player, 200);
    try std.testing.expectEqual(@as(usize, 1), rig.player.changes.items.len);
    try std.testing.expectEqual(@as(usize, 0), rig.player.received(.chunk_radius_updated));
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_committed);
    try std.testing.expectEqual(@as(u32, 0), rig.b.spawns.load(.acquire));

    try rig.player.releaseAcks();
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try std.testing.expectEqual(@as(u32, 1), rig.b.spawns.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), rig.player.received(.level_chunk));
}

test "a target that floods during the switch is paused, not failed" {
    var rig: Rig = undefined;
    // A client still loading the new dimension isn't a slow connection, however short that limit is
    try rig.start(.{ .b = .chatter, .slow_player_timeout_ms = 300 });
    defer rig.deinit();
    rig.player.hold_acks = true;

    try rig.transfer(1);
    try waitForChanges(&rig, 1);
    try pumpFor(rig.player, 2_500);
    try std.testing.expectEqual(@as(u64, 0), rig.stats().slow_players);
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_failed_after_commit);

    try rig.player.releaseAcks();
    try rig.waitFor(.transfers_committed, 1);
    try std.testing.expect(try rig.player.countGamePackets("chatter", 300) >= 128);
    const echoes = rig.b.echoes.load(.acquire);
    var buffer: [32]u8 = undefined;
    try rig.player.send(&.{try managed.rawPacket(&buffer, managed.game_packet_id, "still here")});
    try fixtures.waitFor(io, &rig.b.echoes, echoes + 1);
}

test "a target that spawns before sending its world still lands once" {
    var rig: Rig = undefined;
    try rig.start(.{ .b = .spawn_first });
    defer rig.deinit();
    try moveTo(&rig, 1, 1);
    try std.testing.expectEqual(@as(usize, 2), rig.player.received(.level_chunk));
    try std.testing.expectEqual(@as(u32, 1), rig.b.spawns.load(.acquire));
}

test "a target that drops right after the switch disconnects the player" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    rig.b.hold_spawn.store(true, .release);

    try rig.transfer(1);
    try waitForChanges(&rig, 2);
    try fixtures.waitFor(io, &rig.b.chunk_requests, 1);
    rig.b.drop_all.store(true, .release);
    try rig.running.waitForStat(.transfers_failed_after_commit, 1);
    try rig.player.awaitClosed();
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_committed);
}

test "hundreds of round trips keep transfer time and memory flat" {
    // Hundreds of WebRTC dials at Debug-speed P-384 time out; the other handoff tests cover Debug
    if (@import("builtin").mode == .debug) return error.SkipZigTest;
    const rounds = 200 * test_options.soak;
    const warm_up = 20;
    var counting: FailOnce = .{ .child = std.testing.allocator, .fail_at = std.math.maxInt(usize), .armed = .init(false) };
    var rig: Rig = undefined;
    try rig.start(.{ .allocator = counting.allocator() });
    defer rig.deinit();

    var durations: [rounds]u64 = undefined;
    var settled: usize = 0;
    for (1..rounds + 1) |round| {
        const started = std.Io.Clock.awake.now(io);
        try moveTo(&rig, round % 2, round);
        durations[round - 1] = @intCast(started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
        if (round == warm_up) settled = counting.liveBytes();
    }
    const stats = rig.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.transfers_failed_before_commit + stats.transfers_failed_after_commit + stats.transfers_timed_out);
    try std.testing.expectEqual(@as(usize, 2 * rounds), rig.player.changes.items.len);
    const live = counting.liveBytes();

    std.mem.sort(u64, &durations, {}, std.sort.asc(u64));
    if (test_options.report) std.debug.print("\n{d} transfers: p50 {d:.2} ms, p99 {d:.2} ms, live bytes {d} after {d} rounds, {d} after {d}\n", .{
        rounds,
        millis(durations[rounds / 2]),
        millis(durations[rounds * 99 / 100]),
        settled,
        warm_up,
        live,
        rounds,
    });
    try std.testing.expect(live <= settled + 64 * 1024);
}

fn millis(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

test "eight players moving at once keep transfer time and memory flat" {
    // Hundreds of WebRTC dials at Debug-speed P-384 time out; the other handoff tests cover Debug
    if (@import("builtin").mode == .debug) return error.SkipZigTest;
    // Every transfer is a full WebRTC dial, so keep the default run short; -Dsoak scales it up
    const rounds = 12 * test_options.soak;
    const warm_up = 4;
    var counting: FailOnce = .{ .child = std.testing.allocator, .fail_at = std.math.maxInt(usize), .armed = .init(false) };
    var rig: Rig = undefined;
    try rig.start(.{ .allocator = counting.allocator() });
    defer rig.deinit();
    var players: [8]*Player = undefined;
    players[0] = rig.player;
    var joined: usize = 1;
    defer for (players[1..joined]) |player| player.destroy();
    for (players[1..], 3..) |*player, seed| {
        player.* = try Player.connect(io, rig.running.address(), @intCast(seed));
        joined += 1;
        try player.*.login("Alex", "2535400000000002");
        try player.*.spawn();
        // The echo only comes back once the proxy has the player in game
        try player.*.echo("joined");
    }
    for (players) |player| player.timeout_ms = 2;

    var durations: [rounds]u64 = undefined;
    var settled: usize = 0;
    for (1..rounds + 1) |round| {
        const started = std.Io.Clock.awake.now(io);
        // Joins alternate between backends, so player n started on backend (n - 1) % 2
        for (1..players.len + 1) |id| try rig.running.proxy.requestTransfer(id, .of((id - 1 + round) % 2));
        const target = round * players.len;
        for (0..5_000) |_| {
            if (rig.stats().transfers_committed >= target) break;
            for (players) |player| player.pump() catch |err| if (err != error.NoMessage) return err;
        } else return error.WaitTimedOut;
        durations[round - 1] = @intCast(started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
        if (round == warm_up) settled = counting.liveBytes();
    }
    const stats = rig.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.transfers_failed_before_commit + stats.transfers_failed_after_commit + stats.transfers_timed_out + stats.transfers_rejected);
    for (players) |player| player.timeout_ms = 5_000;
    for (players) |player| try player.echo("still here");
    const live = counting.liveBytes();

    std.mem.sort(u64, &durations, {}, std.sort.asc(u64));
    if (test_options.report) std.debug.print("\n{d} rounds of 8 concurrent transfers: p50 {d:.2} ms, p95 {d:.2} ms, p99 {d:.2} ms, live bytes {d} after {d} rounds, {d} after {d}\n", .{
        rounds,
        millis(durations[rounds / 2]),
        millis(durations[rounds * 95 / 100]),
        millis(durations[rounds * 99 / 100]),
        settled,
        warm_up,
        live,
        rounds,
    });
    try std.testing.expect(live <= settled + 64 * 1024);
}
