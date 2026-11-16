const std = @import("std");
const bedwire = @import("bedwire");
const nethernet = @import("nethernet");

/// Microsoft's signing keys for Logins and signaling. A reload swaps the whole set; logins holding the old one finish with it.
const Keys = @This();
const log = @import("../log.zig").scoped(.auth);

pub const check_interval_s = 60;
pub const max_bytes = limits.max_jwks_bytes;
// A login signed with a key we don't know asks for a download, at most this often
const stale_retry_s = 5 * 60;
const download_timeout_s = 15;

const limits: bedwire.Limits = .{};
const issuer = nethernet.identity_issuer;

pub const Snapshot = struct {
    refs: std.atomic.Value(u32) = .init(1),
    login: bedwire.auth.KeySet,
    signaling: issuer.Keys,
};

gpa: std.mem.Allocator,
io: std.Io,
path: ?[]const u8 = null,
refresh_s: u64 = 0,
mutex: std.Io.Mutex = .init,
current: *Snapshot,
digest: u64 = 0,
// What the file held when last read or written, so a download the file couldn't take isn't reverted by the next reload
file_digest: u64 = 0,
stale: std.atomic.Value(bool) = .init(false),
reload_failing: bool = false,
download_failing: bool = false,

pub fn parse(gpa: std.mem.Allocator, io: std.Io, json: []const u8) !Keys {
    return .{ .gpa = gpa, .io = io, .current = try snapshot(gpa, json), .digest = std.hash.Wyhash.hash(0, json) };
}

/// Keeps `path`, which must outlive the keys, to reload from and save downloads to.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Keys {
    const json = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes));
    defer gpa.free(json);
    var self = try parse(gpa, io, json);
    self.path = path;
    self.file_digest = self.digest;
    return self;
}

pub fn deinit(self: *Keys) void {
    self.release(self.current);
    self.* = undefined;
}

pub fn acquire(self: *Keys) *Snapshot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    _ = self.current.refs.fetchAdd(1, .monotonic);
    return self.current;
}

pub fn release(self: *Keys, keys: *Snapshot) void {
    if (keys.refs.fetchSub(1, .acq_rel) != 1) return;
    keys.login.deinit();
    keys.signaling.deinit();
    self.gpa.destroy(keys);
}

pub fn count(self: *Keys) usize {
    const keys = self.acquire();
    defer self.release(keys);
    return keys.login.count;
}

/// Any thread. A token named a key we don't have, so Microsoft may have rotated them.
pub fn markStale(self: *Keys) void {
    self.stale.store(true, .release);
}

/// Reads the file again and swaps the keys when its contents changed. A file that won't parse, say one caught
/// mid-write, leaves the current keys in place and is tried again next time.
pub fn reload(self: *Keys) !bool {
    const path = self.path orelse return false;
    const json = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(max_bytes));
    defer self.gpa.free(json);
    const digest = std.hash.Wyhash.hash(0, json);
    if (digest == self.file_digest) return false;
    const changed = try self.replace(json);
    self.file_digest = digest;
    return changed;
}

pub fn replace(self: *Keys, json: []const u8) !bool {
    const digest = std.hash.Wyhash.hash(0, json);
    if (digest == self.digest) return false;
    const fresh = try snapshot(self.gpa, json);
    self.digest = digest;
    const old = old: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const old = self.current;
        self.current = fresh;
        break :old old;
    };
    self.release(old);
    return true;
}

pub fn download(self: *Keys) !bool {
    const json = try fetch(self.gpa, self.io);
    defer self.gpa.free(json);
    if (!try self.replace(json)) return false;
    const path = self.path orelse return true;
    if (save(self.io, path, json)) {
        self.file_digest = self.digest;
    } else |err| {
        if (err == error.Canceled) return err;
        log.warn("Can't save Microsoft's signing keys to {s}, so the next start loads the old ones: {t}", .{ path, err });
    }
    return true;
}

fn save(io: std.Io, path: []const u8, json: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, json);
    try file.file.sync(io);
    try file.replace(io);
}

/// Follows the file once a minute, and downloads every `refresh_s` or soon after an unknown key, until canceled.
pub fn watch(self: *Keys) void {
    var since_download_s: u64 = 0;
    while (true) {
        self.io.sleep(.fromSeconds(check_interval_s), .awake) catch return;
        since_download_s += check_interval_s;
        if (self.reload()) |changed| {
            if (changed) log.info("Reloaded {d} Microsoft signing keys from {s}", .{ self.count(), self.path.? });
            self.reload_failing = false;
        } else |err| {
            if (err == error.Canceled) return;
            if (!self.reload_failing) log.warn("Can't reload Microsoft's signing keys from {s}, keeping the {d} loaded: {t}", .{ self.path.?, self.count(), err });
            self.reload_failing = true;
        }
        if (self.refresh_s == 0) continue;
        const stale = self.stale.load(.acquire) and since_download_s >= stale_retry_s;
        if (!stale and since_download_s < self.refresh_s) continue;
        since_download_s = 0;
        self.stale.store(false, .release);
        if (self.download()) |changed| {
            if (changed) log.info("Downloaded {d} new Microsoft signing keys", .{self.count()}) else log.debug("Microsoft's signing keys haven't changed", .{});
            self.download_failing = false;
        } else |err| {
            if (err == error.Canceled) return;
            if (!self.download_failing) log.warn("Can't download Microsoft's signing keys, keeping the {d} loaded: {t}", .{ self.count(), err });
            self.download_failing = true;
        }
    }
}

fn fetch(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const Result = union(enum) { body: anyerror![]u8, timeout: std.Io.Cancelable!void };
    var results: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &results);
    defer while (select.cancel()) |pending| if (pending == .body) {
        const body = pending.body catch continue;
        gpa.free(body);
    };
    try select.concurrent(.timeout, std.Io.sleep, .{ io, std.Io.Duration.fromSeconds(download_timeout_s), .awake });
    try select.concurrent(.body, get, .{ gpa, io });
    return switch (try select.await()) {
        .body => |body| body,
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    };
}

fn get(gpa: std.mem.Allocator, io: std.Io) anyerror![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const buffer = try gpa.alloc(u8, max_bytes);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    const result = try client.fetch(.{ .location = .{ .url = issuer.minecraft_keys_url }, .response_writer = &writer });
    if (result.status != .ok) return error.KeysUnavailable;
    return gpa.dupe(u8, writer.buffered());
}

fn snapshot(gpa: std.mem.Allocator, json: []const u8) !*Snapshot {
    var login = try bedwire.auth.KeySet.parse(gpa, json, limits);
    errdefer login.deinit();
    const signaling = try issuer.Keys.init(gpa, json, issuer.minecraft_issuer, issuer.minecraft_audience);
    errdefer signaling.deinit();
    const keys = try gpa.create(Snapshot);
    keys.* = .{ .login = login, .signaling = signaling };
    return keys;
}
