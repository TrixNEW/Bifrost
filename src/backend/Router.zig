const std = @import("std");
const Config = @import("../config/Config.zig");
const Backend = @import("Backend.zig");
const Health = @import("Health.zig");

const Router = @This();

pub const Set = struct {
    bits: std.StaticBitSet(Config.max_backends) = .empty,

    pub fn add(self: *Set, id: Backend.Id) void {
        self.bits.set(id.index());
    }

    pub fn contains(self: Set, id: Backend.Id) bool {
        return self.bits.isSet(id.index());
    }

    pub fn count(self: Set) usize {
        return self.bits.count();
    }
};

backends: []const Backend,
health: ?*Health,
join: []const Backend.Id,
fallback: []const Backend.Id,
balance: Config.Balance,
next: usize = 0,

pub fn init(config: *const Config, health: ?*Health) Router {
    std.debug.assert(config.backend_count != 0);
    return .{
        .backends = config.backends(),
        .health = health,
        .join = config.joinBackends(),
        .fallback = config.fallbackBackends(),
        .balance = config.balance,
    };
}

/// Picks a backend for a new player and holds their place there until `release`.
pub fn claim(self: *Router, skip: Set, healthy_only: bool) ?Backend.Id {
    if (self.claimFrom(self.join, skip, healthy_only, self.balance)) |id| return id;
    return self.claimFrom(self.fallback, skip, healthy_only, .first);
}

pub fn release(self: *Router, id: Backend.Id) void {
    if (self.health) |health| health.release(id);
}

/// Holds a place on a transfer target, or says why it can't take the player.
pub fn claimTarget(self: *Router, id: Backend.Id) error{ BackendDown, BackendDraining, BackendFull }!void {
    const health = self.health orelse return;
    if (health.status(id) == .unhealthy) return error.BackendDown;
    if (health.isDraining(id)) return error.BackendDraining;
    if (!health.claim(id)) return error.BackendFull;
}

pub fn get(self: *const Router, id: Backend.Id) *const Backend {
    return &self.backends[id.index()];
}

fn eligible(self: *const Router, id: Backend.Id, skip: Set, healthy_only: bool) bool {
    if (skip.contains(id)) return false;
    const health = self.health orelse return !healthy_only;
    if (health.isDraining(id)) return false;
    const status = health.status(id);
    return status != .unhealthy and (!healthy_only or status == .healthy);
}

fn claimFrom(self: *Router, pool: []const Backend.Id, skip: Set, healthy_only: bool, balance: Config.Balance) ?Backend.Id {
    var passed = skip;
    for (0..pool.len) |_| {
        const id = self.choose(pool, passed, healthy_only, balance) orelse return null;
        const health = self.health orelse return id;
        if (health.claim(id)) return id;
        passed.add(id);
    }
    return null;
}

fn choose(self: *Router, pool: []const Backend.Id, skip: Set, healthy_only: bool, balance: Config.Balance) ?Backend.Id {
    switch (balance) {
        .first => for (pool) |id| {
            if (self.eligible(id, skip, healthy_only)) return id;
        },
        .round_robin => for (0..pool.len) |_| {
            const id = pool[self.next % pool.len];
            self.next +%= 1;
            if (self.eligible(id, skip, healthy_only)) return id;
        },
        .least_players => {
            // Ties go round robin, so an empty pool still spreads out
            const start = self.next;
            self.next +%= 1;
            var best: ?Backend.Id = null;
            var fewest: u32 = std.math.maxInt(u32);
            for (0..pool.len) |offset| {
                const id = pool[(start +% offset) % pool.len];
                if (!self.eligible(id, skip, healthy_only)) continue;
                const players = if (self.health) |health| health.proxied(id) else 0;
                if (players < fewest) {
                    best = id;
                    fewest = players;
                }
            }
            return best;
        },
    }
    return null;
}

const none: Set = .{};

fn testConfig(comptime count: usize) !Config {
    var config: Config = .{};
    for (1..count + 1) |port| try config.addBackend(null, .{ .ip4 = .loopback(@intCast(port)) });
    config.joinAll();
    return config;
}

fn claimPort(router: *Router) !u16 {
    return router.get(router.claim(none, false) orelse return error.NoBackend).address.getPort();
}

test "claims cycle through the join backends in order" {
    const config = try testConfig(2);
    var router: Router = .init(&config, null);
    for ([_]u16{ 1, 2, 1, 2 }) |port| try std.testing.expectEqual(port, try claimPort(&router));
}

test "only the first backend takes new players unless routing says otherwise" {
    var config: Config = .{};
    for (1..4) |port| try config.addBackend(null, .{ .ip4 = .loopback(@intCast(port)) });
    var router: Router = .init(&config, null);
    for (0..3) |_| try std.testing.expectEqual(@as(u16, 1), try claimPort(&router));
    var tried: Set = .{};
    tried.add(.of(0));
    try std.testing.expectEqual(@as(?Backend.Id, null), router.claim(tried, false));
}

test "a claim never returns a skipped backend" {
    const config = try testConfig(3);
    var router: Router = .init(&config, null);
    var tried: Set = .{};
    for (0..3) |_| tried.add(router.claim(tried, false).?);
    try std.testing.expectEqual(@as(usize, 3), tried.count());
    try std.testing.expectEqual(@as(?Backend.Id, null), router.claim(tried, false));
}

test "claims skip unhealthy backends and fail when none are left" {
    const config = try testConfig(3);
    var health: Health = .init(config.backends(), 1000, 100);
    var router: Router = .init(&config, &health);

    health.markFailed(.of(1));
    for ([_]u16{ 1, 3, 1, 3 }) |port| try std.testing.expectEqual(port, try claimPort(&router));

    health.markFailed(.of(0));
    health.markFailed(.of(2));
    try std.testing.expectEqual(@as(?Backend.Id, null), router.claim(none, false));
}

test "healthy_only skips backends health checks haven't vouched for" {
    const config = try testConfig(2);
    var health: Health = .init(config.backends(), 1000, 100);
    var router: Router = .init(&config, &health);
    try std.testing.expectEqual(@as(?Backend.Id, null), router.claim(none, true));
    health.entries[1].status.store(.healthy, .release);
    try std.testing.expectEqual(@as(?Backend.Id, .of(1)), router.claim(none, true));
    var unchecked: Router = .init(&config, null);
    try std.testing.expectEqual(@as(?Backend.Id, null), unchecked.claim(none, true));
}

test "fallbacks take players only once every join backend is out" {
    var config: Config = .{};
    for ([_][]const u8{ "lobby-1", "lobby-2", "limbo", "survival" }, 1..) |name, port| try config.addBackend(name, .{ .ip4 = .loopback(@intCast(port)) });
    try config.addJoin("lobby-1");
    try config.addJoin("lobby-2");
    try config.addFallback("limbo");
    try std.testing.expectError(error.DuplicateRoute, config.addFallback("lobby-1"));
    try std.testing.expectError(error.UnknownBackend, config.addJoin("missing"));
    var health: Health = .init(config.backends(), 1000, 100);
    var router: Router = .init(&config, &health);

    health.markFailed(.of(0));
    try std.testing.expectEqual(@as(u16, 2), try claimPort(&router));
    try std.testing.expect(health.setDraining(.of(1), true));
    try std.testing.expectEqual(@as(u16, 3), try claimPort(&router));
    health.markFailed(.of(2));
    try std.testing.expectEqual(@as(?Backend.Id, null), router.claim(none, false));
    try std.testing.expectEqual(@as(u32, 0), health.proxied(.of(3)));
}

test "least_players fills the emptiest backend and claims respect max_players" {
    var config = try testConfig(2);
    config.balance = .least_players;
    config.backend_storage[0].max_players = 2;
    var health: Health = .init(config.backends(), 1000, 100);
    var router: Router = .init(&config, &health);

    for (0..4) |_| _ = router.claim(none, false).?;
    try std.testing.expectEqual(@as(u32, 2), health.proxied(.of(0)));
    try std.testing.expectEqual(@as(u32, 2), health.proxied(.of(1)));
    // The first backend is full, so the rest go to the second
    for (0..2) |_| try std.testing.expectEqual(@as(?Backend.Id, .of(1)), router.claim(none, false));
    router.release(.of(0));
    try std.testing.expectEqual(@as(?Backend.Id, .of(0)), router.claim(none, false));
    try std.testing.expectError(error.BackendFull, router.claimTarget(.of(0)));
    try router.claimTarget(.of(1));
    try std.testing.expectEqual(@as(u32, 5), health.proxied(.of(1)));
}

test "draining and down backends refuse transfers" {
    const config = try testConfig(2);
    var health: Health = .init(config.backends(), 1000, 100);
    var router: Router = .init(&config, &health);
    try std.testing.expect(health.setDraining(.of(1), true));
    try std.testing.expect(!health.setDraining(.of(1), true));
    try std.testing.expectError(error.BackendDraining, router.claimTarget(.of(1)));
    health.markFailed(.of(0));
    try std.testing.expectError(error.BackendDown, router.claimTarget(.of(0)));
    try std.testing.expectEqual(@as(u32, 0), health.proxied(.of(0)) + health.proxied(.of(1)));
}
