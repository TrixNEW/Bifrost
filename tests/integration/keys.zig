const std = @import("std");
const bifrost = @import("bifrost");
const oidc_key = @import("../support/oidc_key.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;
const rotated_kid = "test-rsa-key-rotated";

const KeysFile = struct {
    dir: testing.TmpDir,
    path: [:0]u8,

    fn init(json: []const u8) !KeysFile {
        var dir = testing.tmpDir(.{});
        errdefer dir.cleanup();
        try dir.dir.writeFile(io, .{ .sub_path = "keys.json", .data = json });
        return .{ .dir = dir, .path = try dir.dir.realPathFileAlloc(io, "keys.json", gpa) };
    }

    fn write(self: *KeysFile, json: []const u8) !void {
        try self.dir.dir.writeFile(io, .{ .sub_path = "keys.json", .data = json });
    }

    fn deinit(self: *KeysFile) void {
        gpa.free(self.path);
        self.dir.cleanup();
    }
};

fn rotated() ![]u8 {
    return std.mem.replaceOwned(u8, gpa, oidc_key.jwks_json, oidc_key.kid, rotated_kid);
}

test "a changed keys file replaces the keys while logins holding the old set finish with it" {
    var file: KeysFile = try .init(oidc_key.jwks_json);
    defer file.deinit();
    var keys: bifrost.Keys = try .load(gpa, io, file.path);
    defer keys.deinit();
    try testing.expect(!try keys.reload());

    const held = keys.acquire();
    const json = try rotated();
    defer gpa.free(json);
    try file.write(json);
    try testing.expect(try keys.reload());
    _ = try held.login.find(oidc_key.kid);
    keys.release(held);

    const now = keys.acquire();
    defer keys.release(now);
    try testing.expectError(error.UnknownKey, now.login.find(oidc_key.kid));
    _ = try now.login.find(rotated_kid);
}

test "a broken keys file keeps the loaded keys until a good one replaces it" {
    var file: KeysFile = try .init(oidc_key.jwks_json);
    defer file.deinit();
    var keys: bifrost.Keys = try .load(gpa, io, file.path);
    defer keys.deinit();

    try file.write("{\"keys\":[");
    if (keys.reload()) |_| return error.ExpectedFailure else |_| {}
    const kept = keys.acquire();
    _ = try kept.login.find(oidc_key.kid);
    keys.release(kept);

    const json = try rotated();
    defer gpa.free(json);
    try file.write(json);
    try testing.expect(try keys.reload());
    try testing.expectEqual(@as(usize, 1), keys.count());
}
