const std = @import("std");
const Outbox = @import("../session/Outbox.zig");

const protocol = @import("bedrock_protocol");
const Vec3f = protocol.Vec3f;

const Handoff = @This();

pub const overworld: i32 = 0;
pub const nether: i32 = 1;
pub const the_end: i32 = 2;

const blank_radius_blocks = 8;

pub const Target = struct {
    dimension: i32,
    position: Vec3f,
};

pub const Progress = enum { sent_target, arrived };

/// How a client answers a dimension change: modern clients close the loading screen we named with
/// an id, older ones send the legacy PlayerAction cause. Opening the screen only says the client
/// saw the change; a handoff's fake world may never let it report finishing.
pub const Ack = union(enum) {
    legacy,
    screen: u32,
    start: u32,
};

target: Target,
via: ?i32,
step: enum { via, target, arrived },
// Modern clients answer a ChangeDimension by closing its loading screen, which names the change
// through the id we sent. These track the id of each handoff's own changes.
via_id: ?u32 = null,
target_id: ?u32 = null,

// Same-dimension moves detour so the client drops its old chunks
pub fn begin(current: i32, target: Target, first_id: u32, outbox: *Outbox) !Handoff {
    const via: ?i32 = if (current != target.dimension) null else if (target.dimension == nether) overworld else nether;
    var self: Handoff = .{ .target = target, .via = via, .step = if (via == null) .target else .via };
    if (via) |dimension| {
        self.via_id = first_id;
        try changeDimension(outbox, dimension, target.position, first_id);
        try blankWorld(outbox, dimension, target.position);
    } else {
        self.target_id = first_id;
        try changeDimension(outbox, target.dimension, target.position, first_id);
    }
    return self;
}

pub fn acknowledged(self: *Handoff, next_id: u32, outbox: *Outbox) !Progress {
    switch (self.step) {
        .via => {
            self.target_id = next_id;
            try changeDimension(outbox, self.target.dimension, self.target.position, next_id);
            self.step = .target;
            return .sent_target;
        },
        .target, .arrived => {
            self.step = .arrived;
            return .arrived;
        },
    }
}

/// The id of the change the client is meant to be acknowledging right now, or null once it has arrived.
pub fn pendingId(self: *const Handoff) ?u32 {
    return switch (self.step) {
        .via => self.via_id,
        .target => self.target_id,
        .arrived => null,
    };
}

/// How many dimension changes the client will acknowledge before it's in the target's world.
pub fn acks(self: *const Handoff) u8 {
    return if (self.via == null) 1 else 2;
}

pub fn arrived(self: *const Handoff) bool {
    return self.step == .arrived;
}

pub fn waitingForTarget(self: *const Handoff) bool {
    return self.step == .via;
}

fn changeDimension(outbox: *Outbox, dimension: i32, position: Vec3f, loading_screen_id: u32) !void {
    try outbox.emit(.{ .change_dimension = .{ .dimension_id = dimension, .position = position, .respawn = false, .loading_screen_id = loading_screen_id } });
}

fn blankWorld(outbox: *Outbox, dimension: i32, position: Vec3f) !void {
    const block: protocol.BlockPosition = .{ .x = blockOf(position.x), .y = blockOf(position.y), .z = blockOf(position.z) };
    try outbox.emit(.{ .network_chunk_publisher_update = .{ .new_position_for_view = block, .new_radius_for_view = blank_radius_blocks, .server_built_chunks_list = .empty } });
    var payload: [2 * 24 + 1]u8 = undefined;
    try outbox.emit(.{ .level_chunk = .{
        .chunk_position = .{ .x = block.x >> 4, .z = block.z >> 4 },
        .dimension_id = dimension,
        .sub_chunks_count = 0,
        .client_request_sub_chunk_limit = null,
        .cache_enabled = false,
        .cache_metadata = .empty,
        .serialized_chunk_data = emptyChunk(&payload, dimension),
        .is_client_biome_update = false,
    } });
}

fn blockOf(coordinate: f32) i32 {
    if (!std.math.isFinite(coordinate)) return 0;
    return std.math.lossyCast(i32, @floor(coordinate));
}

// One single-value biome palette per section, then no border blocks
fn emptyChunk(buffer: *[2 * 24 + 1]u8, dimension: i32) []const u8 {
    const sections: usize, const biome: u8 = switch (dimension) {
        nether => .{ 8, 8 },
        the_end => .{ 16, 9 },
        else => .{ 24, 1 },
    };
    for (0..sections) |i| buffer[2 * i ..][0..2].* = .{ 1, biome << 1 };
    buffer[2 * sections] = 0;
    return buffer[0 .. 2 * sections + 1];
}

/// Sent before the client saw the switch, these name the old backend's forms, entities, windows or
/// positions, so the target must never get them.
pub fn staleDuringSync(kind: ?protocol.PacketKind) bool {
    return switch (kind orelse return false) {
        .player_auth_input,
        .player_action,
        .server_bound_loading_screen,
        .move_player,
        .command_request,
        .modal_form_response,
        .inventory_transaction,
        .item_stack_request,
        .mob_equipment,
        .interact,
        .animate,
        .emote,
        .actor_pick_request,
        .block_pick_request,
        .block_actor_data,
        .container_close,
        .npc_request,
        .book_edit,
        .lectern_update,
        .set_local_player_as_initialised,
        .server_bound_data_driven_screen_closed,
        => true,
        else => false,
    };
}

pub fn isAck(packet: protocol.BorrowedEnvelope) ?Ack {
    if (packet.value != .typed) return null;
    return switch (packet.value.typed) {
        .player_action => if (packet.value.typed.player_action.action == .changedimensionack) Ack.legacy else null,
        .server_bound_loading_screen => |screen| switch (screen.loading_screen_packet_type) {
            .endloadingscreen => if (screen.loading_screen_id) |id| Ack{ .screen = id } else null,
            .startloadingscreen => if (screen.loading_screen_id) |id| Ack{ .start = id } else null,
            else => null,
        },
        else => null,
    };
}

fn sent(outbox: *Outbox, kinds: []protocol.PacketKind, dimensions: []i32) !usize {
    var packets: [8][]const u8 = undefined;
    var changes: usize = 0;
    for (outbox.slices(0, &packets), 0..) |packet, i| {
        const decoded = try protocol.Current.decodeBorrowed(packet, .{});
        kinds[i] = decoded.kind.?;
        if (decoded.value.typed == .change_dimension) {
            dimensions[changes] = decoded.value.typed.change_dimension.dimension_id;
            changes += 1;
        }
    }
    outbox.bytes.clearRetainingCapacity();
    outbox.lengths.clearRetainingCapacity();
    return changes;
}

test "a move within one dimension detours through another" {
    var outbox: Outbox = .init(std.testing.allocator);
    defer outbox.deinit();
    var kinds: [8]protocol.PacketKind = undefined;
    var dimensions: [4]i32 = undefined;

    var handoff = try begin(overworld, .{ .dimension = overworld, .position = .{ .x = 10, .y = 64, .z = -20 } }, 7, &outbox);
    try std.testing.expectEqual(@as(usize, 1), try sent(&outbox, &kinds, &dimensions));
    try std.testing.expectEqual(nether, dimensions[0]);
    try std.testing.expectEqual(protocol.PacketKind.network_chunk_publisher_update, kinds[1]);
    try std.testing.expectEqual(protocol.PacketKind.level_chunk, kinds[2]);
    try std.testing.expect(handoff.waitingForTarget());
    try std.testing.expectEqual(@as(?u32, 7), handoff.pendingId());

    try std.testing.expectEqual(Progress.sent_target, try handoff.acknowledged(8, &outbox));
    try std.testing.expectEqual(@as(usize, 1), try sent(&outbox, &kinds, &dimensions));
    try std.testing.expectEqual(overworld, dimensions[0]);
    try std.testing.expectEqual(@as(?u32, 8), handoff.pendingId());
    try std.testing.expectEqual(Progress.arrived, try handoff.acknowledged(9, &outbox));
    try std.testing.expectEqual(Progress.arrived, try handoff.acknowledged(10, &outbox));
    try std.testing.expectEqual(@as(?u32, null), handoff.pendingId());
    try std.testing.expectEqual(@as(usize, 0), outbox.count());

    _ = try begin(nether, .{ .dimension = nether, .position = .{ .x = 0, .y = 0, .z = 0 } }, 1, &outbox);
    _ = try sent(&outbox, &kinds, &dimensions);
    try std.testing.expectEqual(overworld, dimensions[0]);
}

test "a move to another dimension goes straight there" {
    var outbox: Outbox = .init(std.testing.allocator);
    defer outbox.deinit();
    var kinds: [8]protocol.PacketKind = undefined;
    var dimensions: [4]i32 = undefined;
    var handoff = try begin(overworld, .{ .dimension = nether, .position = .{ .x = 0, .y = 70, .z = 0 } }, 5, &outbox);
    try std.testing.expectEqual(@as(usize, 1), outbox.count());
    _ = try sent(&outbox, &kinds, &dimensions);
    try std.testing.expectEqual(nether, dimensions[0]);
    try std.testing.expect(!handoff.waitingForTarget());
    try std.testing.expectEqual(@as(?u32, 5), handoff.pendingId());
    try std.testing.expectEqual(Progress.arrived, try handoff.acknowledged(6, &outbox));
}

test "handoff changes carry a loading screen id and modern clients answer it" {
    var outbox: Outbox = .init(std.testing.allocator);
    defer outbox.deinit();
    var packets: [8][]const u8 = undefined;

    var handoff = try begin(overworld, .{ .dimension = overworld, .position = .{ .x = 0, .y = 64, .z = 0 } }, 0xffff_0001, &outbox);
    try std.testing.expectEqual(@as(?u32, 0xffff_0001), handoff.pendingId());
    const change = try protocol.Current.decodeBorrowed(outbox.slices(0, &packets)[0], .{});
    try std.testing.expectEqual(@as(?u32, 0xffff_0001), change.value.typed.change_dimension.loading_screen_id);
    outbox.bytes.clearRetainingCapacity();
    outbox.lengths.clearRetainingCapacity();

    try outbox.emit(.{ .server_bound_loading_screen = .{ .loading_screen_packet_type = .startloadingscreen, .loading_screen_id = 0xffff_0001 } });
    try outbox.emit(.{ .server_bound_loading_screen = .{ .loading_screen_packet_type = .endloadingscreen, .loading_screen_id = 0xffff_0001 } });
    const answers = outbox.slices(0, &packets);
    try std.testing.expectEqual(@as(?Ack, .{ .start = 0xffff_0001 }), isAck(try protocol.Current.decodeBorrowed(answers[0], .{})));
    try std.testing.expectEqual(@as(?Ack, .{ .screen = 0xffff_0001 }), isAck(try protocol.Current.decodeBorrowed(answers[1], .{})));

    // Opening and closing the target's screen settle the second step
    try std.testing.expectEqual(Progress.sent_target, try handoff.acknowledged(0xffff_0002, &outbox));
    try std.testing.expectEqual(@as(?u32, 0xffff_0002), handoff.pendingId());
    try std.testing.expectEqual(Progress.arrived, try handoff.acknowledged(0xffff_0003, &outbox));
}

test "a hostile spawn position still gives a valid blank chunk" {
    var outbox: Outbox = .init(std.testing.allocator);
    defer outbox.deinit();
    _ = try begin(the_end, .{ .dimension = the_end, .position = .{ .x = std.math.nan(f32), .y = std.math.inf(f32), .z = -1e30 } }, 3, &outbox);
    try std.testing.expectEqual(@as(usize, 3), outbox.count());
}
