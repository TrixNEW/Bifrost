const std = @import("std");
const bedwire = @import("bedwire");

pub const Ecdsa = bedwire.crypto.spki.Ecdsa;

const hex_len = Ecdsa.SecretKey.encoded_length * 2;
const has_modes = @hasDecl(std.Io.File.Permissions, "fromMode");
const owner_only: std.Io.File.Permissions = if (has_modes) .fromMode(0o600) else .default_file;

// Creates the key if it's missing
pub fn load(io: std.Io, path: []const u8) !Ecdsa.KeyPair {
    for (0..8) |_| {
        var buffer: [hex_len + 16]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        if (std.Io.Dir.cwd().readFile(io, path, &buffer)) |text| {
            return parse(std.mem.trim(u8, text, " \t\r\n"));
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        // Written aside and linked into place, so a crash never leaves half a key and two starts can't both win
        const key = Ecdsa.KeyPair.generate(io);
        var line = std.fmt.bytesToHex(key.secret_key.toBytes(), .lower) ++ "\n".*;
        defer std.crypto.secureZero(u8, &line);
        var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .permissions = owner_only });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, &line);
        try file.file.sync(io);
        file.link(io) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return key;
    }
    return error.ProxyKeyRaceLost;
}

/// The file's mode when anyone besides its owner may read or change it. Only POSIX has modes to check.
pub fn exposedMode(io: std.Io, path: []const u8) ?u32 {
    if (!has_modes) return null;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    const mode: u32 = @intCast(stat.permissions.toMode() & 0o777);
    return if (mode & 0o077 != 0) mode else null;
}

pub fn parse(text: []const u8) error{InvalidProxyKey}!Ecdsa.KeyPair {
    if (text.len != hex_len) return error.InvalidProxyKey;
    var secret: [Ecdsa.SecretKey.encoded_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    _ = std.fmt.hexToBytes(&secret, text) catch return error.InvalidProxyKey;
    const secret_key = Ecdsa.SecretKey.fromBytes(secret) catch return error.InvalidProxyKey;
    return Ecdsa.KeyPair.fromSecretKey(secret_key) catch error.InvalidProxyKey;
}

pub fn publicText(key: Ecdsa.KeyPair) [160]u8 {
    return bedwire.auth.login.encodedPublicKey(key.public_key);
}

test "load creates a key once, private to its owner, and reads the same key back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "proxy.key" });
    defer std.testing.allocator.free(path);

    const created = try load(io, path);
    const loaded = try load(io, path);
    try std.testing.expectEqualSlices(u8, &created.secret_key.toBytes(), &loaded.secret_key.toBytes());
    try std.testing.expectEqualSlices(u8, &publicText(created), &publicText(loaded));
    try std.testing.expectEqual(@as(?u32, null), exposedMode(io, path));
}

test "parse rejects anything but a hex P-384 scalar" {
    try std.testing.expectError(error.InvalidProxyKey, parse(""));
    try std.testing.expectError(error.InvalidProxyKey, parse(&@as([hex_len]u8, @splat('z'))));
    try std.testing.expectError(error.InvalidProxyKey, parse(&@as([hex_len]u8, @splat('0'))));
    try std.testing.expectError(error.InvalidProxyKey, parse(&@as([hex_len - 2]u8, @splat('1'))));
}
