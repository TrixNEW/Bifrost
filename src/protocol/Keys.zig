const std = @import("std");
const bedwire = @import("bedwire");
const nethernet = @import("nethernet");

/// Microsoft's signing keys, for Logins and for the identity players prove at signaling. Microsoft rotates them, so
/// a changed keys file replaces the whole set while logins already holding the old one finish with it.
const Keys = @This();
const log = @import("../log.zig").scoped(.auth);

pub const check_interval_s = 60;
pub const max_bytes = limits.max_jwks_bytes;

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
mutex: std.Io.Mutex = .init,
current: *Snapshot,
digest: u64 = 0,
failing: bool = false,

pub fn parse(gpa: std.mem.Allocator, io: std.Io, json: []const u8) !Keys {
    return .{ .gpa = gpa, .io = io, .current = try snapshot(gpa, json) };
}

/// Keeps `path`, which must outlive the keys, to reload from.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Keys {
    const json = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes));
    defer gpa.free(json);
    var self = try parse(gpa, io, json);
    self.path = path;
    self.digest = std.hash.Wyhash.hash(0, json);
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

/// Reads the file again and swaps the keys when its contents changed. A file that won't parse, say one caught mid-write, leaves the current
/// keys in place and is tried again next time.
pub fn reload(self: *Keys) !bool {
    const path = self.path orelse return false;
    const json = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(max_bytes));
    defer self.gpa.free(json);
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

/// Checks the file once a minute until canceled.
pub fn watch(self: *Keys) void {
    while (true) {
        self.io.sleep(.fromSeconds(check_interval_s), .awake) catch return;
        const changed = self.reload() catch |err| {
            if (!self.failing) log.warn("Can't reload Microsoft's signing keys from {s}, keeping the {d} loaded: {t}", .{ self.path.?, self.count(), err });
            self.failing = true;
            continue;
        };
        if (self.failing and !changed) continue;
        if (self.failing) log.info("Signing keys file {s} is readable again", .{self.path.?});
        self.failing = false;
        if (changed) log.info("Reloaded {d} Microsoft signing keys from {s}", .{ self.count(), self.path.? });
    }
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
