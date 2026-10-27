const protocol = @import("bedwire").protocol;
const abi = @import("abi.zig");

pub const max_packet_bytes = 128 * 1024;

pub fn validate(target: abi.PacketTarget, bytes: []const u8) abi.Status {
    if (target != .player and target != .backend) return .invalid_argument;
    if (bytes.len == 0 or bytes.len > max_packet_bytes) return .invalid_argument;
    const limits: protocol.DecodeLimits = .{ .max_packet_bytes = max_packet_bytes };
    const packet = protocol.packet.decode(bytes, limits) catch return .invalid_argument;
    if (packet.header.sender_subclient != 0 or packet.header.target_subclient != 0) return .unsupported;
    switch (protocol.Current.packetKind(packet.header.packet_id) orelse return .unsupported) {
        .text, .player_skin => {},
        .toast_request, .network_stack_latency => if (target != .player) return .unsupported,
        .request_chunk_radius, .script_message => if (target != .backend) return .unsupported,
        else => return .unsupported,
    }
    const decoded = protocol.Current.decodeBorrowed(bytes, limits) catch return .invalid_argument;
    if (decoded.value.typed == .request_chunk_radius and decoded.value.typed.request_chunk_radius.chunk_radius < 0) return .invalid_argument;
    return .ok;
}

test "script messages can only be injected into backends" {
    const testing = @import("std").testing;
    const script = [_]u8{ 0xb1, 1, 1, 'x', 1, 'y' };
    try testing.expectEqual(abi.Status.ok, validate(.backend, &script));
    try testing.expectEqual(abi.Status.unsupported, validate(.player, &script));
    for (0..script.len) |len| try testing.expectEqual(abi.Status.invalid_argument, validate(.backend, script[0..len]));
    try testing.expectEqual(abi.Status.invalid_argument, validate(.backend, &.{ 0xb1, 1, 255, 255, 255, 255, 15 }));
}

test "network stack latency markers can only be injected into players" {
    const testing = @import("std").testing;
    const marker = [_]u8{ 115, 0xe8, 3, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expectEqual(abi.Status.ok, validate(.player, &marker));
    try testing.expectEqual(abi.Status.unsupported, validate(.backend, &marker));
    for (0..marker.len) |len| try testing.expectEqual(abi.Status.invalid_argument, validate(.player, marker[0..len]));
    try testing.expectEqual(abi.Status.invalid_argument, validate(.player, &.{ 115, 0xe8, 3, 0, 0, 0, 0, 0, 0, 2 }));
    try testing.expectEqual(abi.Status.unsupported, validate(.player, &.{ 0xf3, 0x10, 0xe8, 3, 0, 0, 0, 0, 0, 0, 1 }));
}

test "packet injection validates supported packets and truncated input" {
    const testing = @import("std").testing;
    const text = [_]u8{ 9, 0, 0, 0, 2, 'h', 'i', 0, 0, 0 };
    for (0..text.len) |len| try testing.expectEqual(abi.Status.invalid_argument, validate(.player, text[0..len]));
    try testing.expectEqual(abi.Status.ok, validate(.player, &text));
    try testing.expectEqual(abi.Status.ok, validate(.backend, &text));
    try testing.expectEqual(abi.Status.invalid_argument, validate(@fromBackingInt(7), &text));
    try testing.expectEqual(abi.Status.unsupported, validate(.player, &.{ 69, 16, 12 }));
    try testing.expectEqual(abi.Status.ok, validate(.backend, &.{ 69, 16, 12 }));
    try testing.expectEqual(abi.Status.invalid_argument, validate(.backend, &.{ 69, 1, 12 }));
    try testing.expectEqual(abi.Status.unsupported, validate(.player, &.{ 1, 0 }));
    try testing.expectEqual(abi.Status.unsupported, validate(.player, &.{ 0x89, 8, 0, 0, 0, 0, 0, 0 }));
    var oversized: [max_packet_bytes + 1]u8 = @splat(0);
    oversized[0] = 9;
    try testing.expectEqual(abi.Status.invalid_argument, validate(.player, &oversized));
    const Decoded = @import("Decoded.zig");
    const message: [65536 - 10]u8 = @splat('x');
    const text_fields: abi.Text = .{ .message = .of(&message) };
    const len = try Decoded.encode(.{ .packet_id = 9 }, .text, &text_fields, oversized[0..max_packet_bytes]);
    try testing.expectEqual(@as(usize, 65536), len);
    try testing.expectEqual(abi.Status.ok, validate(.player, oversized[0..len]));
    try testing.expectEqual(abi.Status.invalid_argument, validate(.player, oversized[0 .. len - 1]));
    var buffer: [4]u8 = undefined;
    for (0..65536) |value| {
        @memcpy(&buffer, &@as([4]u8, @bitCast(@as(u32, @intCast(value)))));
        _ = validate(.player, &buffer);
        _ = validate(.backend, &buffer);
    }
}

test "skin and toast injection validates direction and supports HD textures" {
    const std = @import("std");
    const testing = std.testing;
    var texture: [128 * 128 * 4]u8 = @splat(255);
    var skin: protocol.types.SerializedSkinRef = .{
        .id = "test",
        .play_fab_id = "",
        .resource_patch = "{}",
        .image_data = .{ .width = 0, .height = 0, .image_bytes = "" },
        .animated_image_data = .empty,
        .cape_image_data = .{ .width = 0, .height = 0, .image_bytes = "" },
        .geometry_data = "",
        .geometry_data_min_engine_version = "",
        .animation_data = "",
        .cape_id = "",
        .full_id = "",
        .arm_size = .wide,
        .skin_color = 0,
        .persona_pieces = .empty,
        .piece_tint_colors = .empty,
        .is_premium = false,
        .is_persona = false,
        .is_persona_cape_on_classic_skin = false,
        .is_primary_user = true,
        .overrides_player_appearance = false,
        .trusted_skin_flag = "",
        .profile_hash = "",
    };
    skin.image_data = .{ .width = 128, .height = 128, .image_bytes = &texture };
    var buffer: [80 * 1024]u8 = undefined;
    var writer = protocol.Writer.init(&buffer);
    try protocol.typed.encode(&writer, .{ .header = .{ .packet_id = protocol.Current.packetId(.player_skin).? }, .packet = .{ .player_skin = .{ .uuid = @splat(0), .serialized_skin = skin, .localized_new_skin_name = "", .localized_old_skin_name = "" } } });
    try testing.expect(writer.written().len > 65536);
    try testing.expectEqual(abi.Status.ok, validate(.backend, writer.written()));
    try testing.expectEqual(abi.Status.ok, validate(.player, writer.written()));
    try testing.expectEqual(abi.Status.invalid_argument, validate(.backend, writer.written()[0 .. writer.written().len - 1]));
    writer = protocol.Writer.init(&buffer);
    try protocol.typed.encode(&writer, .{ .header = .{ .packet_id = protocol.Current.packetId(.toast_request).? }, .packet = .{ .toast_request = .{ .title = "Skin", .content = "Replaced" } } });
    try testing.expectEqual(abi.Status.ok, validate(.player, writer.written()));
    try testing.expectEqual(abi.Status.unsupported, validate(.backend, writer.written()));
}

test "native packet codec and injection fuzz round trips" {
    const std = @import("std");
    const Decoded = @import("Decoded.zig");
    var buffers: [16][1028]u8 = undefined;
    var corpus: [16][]const u8 = undefined;
    for (&buffers, &corpus, 0..) |*buffer, *seed, tag| {
        const out = buffer[4..];
        const len = if (tag < 12) blk: {
            var text: abi.Text = .{ .message_type = @fromBackingInt(@intCast(tag)), .message = .of("hello"), .xuid = .of("123"), .platform_id = .of("platform"), .has_filtered_message = 1, .filtered_message = .of("filtered") };
            switch (text.message_type) {
                .chat, .whisper, .announcement => text.source = .of("Steve"),
                .translate, .popup, .jukebox_popup => {
                    text.parameter_count = 4;
                    for (&text.parameters) |*parameter| parameter.* = .of("parameter");
                },
                else => {},
            }
            break :blk try Decoded.encode(.{ .packet_id = 9 }, .text, &text, out);
        } else if (tag < 14)
            try Decoded.encode(.{ .packet_id = 69 }, .chunk_radius, &abi.ChunkRadius{ .radius = if (tag == 12) 8 else -1, .max_radius = 255 }, out)
        else if (tag == 14) blk: {
            var writer = protocol.Writer.init(out);
            try writer.writeVarU32(protocol.Current.packetId(.script_message).?);
            const script: protocol.packets.script_message.Packet = .{ .message_id = "suko:staff_rank", .message_value = "Moderator" };
            try script.encode(&writer);
            break :blk writer.written().len;
        } else blk: {
            var writer = protocol.Writer.init(out);
            try writer.writeVarU32(protocol.Current.packetId(.network_stack_latency).?);
            const marker: protocol.packets.network_stack_latency.Packet = .{ .creation_time = 1000, .is_from_server = true };
            try marker.encode(&writer);
            break :blk writer.written().len;
        };
        std.mem.writeInt(u32, buffer[0..4], @intCast(len), .little);
        seed.* = buffer[0 .. 4 + len];
    }
    try std.testing.fuzz({}, struct {
        fn check(_: void, smith: *std.testing.Smith) !void {
            var buffer: [1024]u8 = undefined;
            const bytes = buffer[0..smith.slice(&buffer)];
            for ([_]abi.PacketTarget{ .player, .backend }) |target| {
                if (validate(target, bytes) == .ok) {
                    const packet = try protocol.Current.decodeBorrowed(bytes, .{ .max_packet_bytes = max_packet_bytes });
                    try std.testing.expect(packet.header.sender_subclient == 0 and packet.header.target_subclient == 0);
                    switch (packet.value.typed) {
                        .text, .player_skin => {},
                        .toast_request, .network_stack_latency => try std.testing.expect(target == .player),
                        .script_message => try std.testing.expect(target == .backend),
                        .request_chunk_radius => |radius| try std.testing.expect(target == .backend and radius.chunk_radius >= 0),
                        else => return error.UnsafeInjectionAccepted,
                    }
                }
            }
            for ([_]abi.PacketType{ .text, .chunk_radius }) |packet_type| {
                const value = Decoded.decode(bytes, packet_type, .{ .max_packet_bytes = buffer.len }) catch continue;
                const header = (try protocol.packet.decode(bytes, .{ .max_packet_bytes = buffer.len })).header;
                var out: [2048]u8 = undefined;
                const len = switch (value) {
                    inline else => |fields| try Decoded.encode(header, packet_type, &fields, &out),
                };
                const result = try Decoded.decode(out[0..len], packet_type, .{});
                try std.testing.expectEqual(header, (try protocol.packet.decode(out[0..len], .{})).header);
                switch (value) {
                    .text => |text| {
                        inline for (.{ "message_type", "localize", "has_filtered_message", "parameter_count" }) |field| try std.testing.expectEqual(@field(text, field), @field(result.text, field));
                        inline for (.{ "source", "message", "xuid", "platform_id", "filtered_message" }) |field| try std.testing.expectEqualStrings(@field(text, field).slice(), @field(result.text, field).slice());
                        for (text.parameters[0..text.parameter_count], result.text.parameters[0..text.parameter_count]) |expected, actual| try std.testing.expectEqualStrings(expected.slice(), actual.slice());
                    },
                    .chunk_radius => |radius| try std.testing.expectEqual(radius, result.chunk_radius),
                }
            }
        }
    }.check, .{ .corpus = &corpus });
}
