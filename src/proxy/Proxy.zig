const std = @import("std");
const bedwire = @import("bedwire");
const Config = @import("../config/Config.zig");
const Health = @import("../backend/Health.zig");
const Router = @import("../backend/Router.zig");
const NetherNet = @import("../net/NetherNet.zig");
const Peer = @import("../net/Peer.zig");
const Observer = @import("../protocol/Observer.zig");
const Managed = @import("../session/Managed.zig");
const proxy_key = @import("../session/proxy_key.zig");
const Admission = @import("Admission.zig");
const Budget = @import("Budget.zig");
const Rate = @import("Rate.zig");
const Backend = @import("../backend/Backend.zig");
const Transfer = @import("../transfer/Transfer.zig");
pub const Link = @import("Link.zig");
const Console = @import("Console.zig");
const Plugins = @import("../plugin/Plugins.zig");
const Handles = Plugins.Handles;
const abi = @import("../plugin/abi.zig");
const Scheduler = @import("Scheduler.zig");
const Stats = @import("Stats.zig");
const Metrics = @import("Metrics.zig");
const trace = @import("../trace.zig");
const clock = @import("../clock.zig");

/// One worker. Owns its links and runs them on one task; other threads only queue work for it.
const Proxy = @This();
const log = @import("../log.zig").scoped(.player);
const console_log = @import("../log.zig").scoped(.console);
const transfer_log = @import("../log.zig").scoped(.transfer);

const mailbox_capacity = 64;
const inbox_capacity = 64;
const sweep_interval_ms = 1_000;
const rejection_log_interval_ms = 10_000;
// When ICE won't say where the player is, they all share one per-IP bucket
const unknown_address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(0) };

pub const TransferRequest = struct { player: u64, target: Backend.Id };

gpa: std.mem.Allocator,
io: std.Io,
config: Config,
router: Router,
scheduler: Scheduler,
admission: *Admission,
own_admission: Admission,
budget: *Budget,
own_budget: Budget,
logins: Rate,
transfers: u32 = 0,
next_sweep_ms: u64 = 0,
rejections_logged_ms: u64 = 0,
rejections_unlogged: u64 = 0,
observer_pool: ?bedwire.BufferPool,
managed: ?Managed.Shared,
env: Link.Env,
links: std.AutoArrayHashMapUnmanaged(u64, *Link) = .empty,
// Links plus connections still in the inbox, for the listener to pick the lightest worker by
players: std.atomic.Value(u32) = .init(0),
stop_requested: std.atomic.Value(bool) = .init(false),
stats: Stats = .{},
timings: Metrics.Timings = .{},
next_player: u64 = 0,
next_epoch: Transfer.State.Epoch = 0,
mailbox_mutex: std.Io.Mutex = .init,
mailbox: [mailbox_capacity]TransferRequest = undefined,
mailbox_len: usize = 0,
inbox: [inbox_capacity]*NetherNet.Connection = undefined,
inbox_len: usize = 0,
console_request: ?Console.Request = null,

pub const Options = struct {
    transport: *const NetherNet,
    auth: Observer.Auth = .off,
    admission: ?*Admission = null,
    budget: ?*Budget = null,
    health: ?*Health = null,
    proxy_key: ?proxy_key.Ecdsa.KeyPair = null,
    plugins: ?*Plugins = null,
    worker: u32 = 0,
};

pub fn create(gpa: std.mem.Allocator, io: std.Io, config: Config, options: Options) !*Proxy {
    try config.validate();
    if (options.plugins) |plugins| {
        if (plugins.admission != null and config.session_mode != .managed) return error.AdmissionRequiresManaged;
    }
    const self = try gpa.create(Proxy);
    errdefer gpa.destroy(self);

    var observer_pool: ?bedwire.BufferPool = if (config.session_mode == .passthrough) try Observer.initPool(gpa) else null;
    errdefer if (observer_pool) |*pool| pool.deinit();
    const own_per_ip = if (options.admission == null) config.max_players_per_ip else 0;
    var own_admission: Admission = try .init(gpa, config.max_players, own_per_ip);
    errdefer own_admission.deinit();
    var managed: ?Managed.Shared = switch (config.session_mode) {
        .passthrough => null,
        .managed => try .init(
            gpa,
            options.proxy_key orelse return error.MissingProxyKey,
            switch (options.auth) {
                .verify => |keys| keys,
                .off => return error.ManagedNeedsVerifiedLogins,
            },
        ),
    };
    errdefer if (managed) |*shared| shared.deinit(gpa);
    if (managed) |*shared| {
        shared.transfers = config.backend_count > 1;
        shared.external_transfers = config.external_transfers;
    }

    self.* = .{
        .gpa = gpa,
        .io = io,
        .config = config,
        .router = undefined,
        .scheduler = .{ .io = io },
        .admission = undefined,
        .own_admission = own_admission,
        .budget = undefined,
        .own_budget = .init(std.math.cast(usize, config.total_pending_bytes) orelse std.math.maxInt(usize)),
        .logins = .init(config.logins_per_second, 2 * @as(u64, config.logins_per_second)),
        .observer_pool = observer_pool,
        .managed = managed,
        .env = undefined,
    };
    self.admission = options.admission orelse &self.own_admission;
    self.budget = options.budget orelse &self.own_budget;
    if (self.managed) |*shared| {
        shared.budget = self.budget;
        shared.logins = &self.logins;
        shared.player_bytes_per_second = config.player_bytes_per_second;
        shared.backends = self.config.backends();
    }
    if (options.plugins) |plugins| {
        plugins.attachWorker(options.worker, self.scheduler.wakeNotify());
        if (self.managed) |*shared| shared.hooks = .{ .plugins = plugins, .worker = options.worker };
    }
    self.router = .init(&self.config, options.health);
    self.env = .{
        .gpa = gpa,
        .io = io,
        .stats = &self.stats,
        .scheduler = &self.scheduler,
        .transport = options.transport,
        .observer_pool = if (self.observer_pool) |*pool| pool else null,
        .auth = options.auth,
        .router = &self.router,
        .pending_packets = config.pending_packets,
        .pending_bytes = config.pending_bytes,
        .budget = self.budget,
        .logins = &self.logins,
        .player_bytes_per_second = config.player_bytes_per_second,
        .deadlines = .{
            .login_ms = config.login_timeout_ms,
            .resource_packs_ms = config.resource_pack_timeout_ms,
            .join_ms = config.join_timeout_ms,
            .slow_player_ms = config.slow_player_timeout_ms,
        },
        .managed = if (self.managed) |*shared| shared else null,
        .transfer = .{
            .limits = .{
                .dial_ms = config.connect_timeout_ms,
                .phase_ms = config.transfer_phase_timeout_ms,
                .total_ms = config.transfer_timeout_ms,
            },
            .queue_packets = config.pending_packets,
            .queue_bytes = config.pending_bytes,
            .content_policy = config.content_policy,
            .budget = self.budget,
        },
        .transfers = &self.transfers,
        .max_transfers = config.max_transfers,
        .next_epoch = &self.next_epoch,
        .events = .{ .plugins = options.plugins, .worker = options.worker },
        .timings = &self.timings,
    };
    return self;
}

pub fn destroy(self: *Proxy) void {
    self.closeAll();
    self.links.deinit(self.gpa);
    if (self.managed) |*shared| shared.deinit(self.gpa);
    self.own_admission.deinit();
    if (self.observer_pool) |*pool| pool.deinit();
    self.gpa.destroy(self);
}

/// Any thread. Takes the connection, or leaves it with the caller when this worker is full or stopping.
pub fn adopt(self: *Proxy, connection: *NetherNet.Connection) error{ Busy, Canceled }!void {
    {
        self.mailbox_mutex.lockUncancelable(self.io);
        defer self.mailbox_mutex.unlock(self.io);
        if (self.stop_requested.load(.acquire)) return error.Canceled;
        if (self.inbox_len == inbox_capacity) return error.Busy;
        self.inbox[self.inbox_len] = connection;
        self.inbox_len += 1;
        _ = self.players.fetchAdd(1, .monotonic);
    }
    self.scheduler.wake.set(self.io);
}

// Any thread; the player's own worker runs it
pub fn requestTransfer(self: *Proxy, player: u64, target: Backend.Id) error{ MailboxFull, Canceled }!void {
    {
        self.mailbox_mutex.lockUncancelable(self.io);
        defer self.mailbox_mutex.unlock(self.io);
        if (self.stop_requested.load(.acquire)) return error.Canceled;
        if (self.mailbox_len == mailbox_capacity) return error.MailboxFull;
        self.mailbox[self.mailbox_len] = .{ .player = player, .target = target };
        self.mailbox_len += 1;
    }
    self.scheduler.wake.set(self.io);
}

/// Any thread. False when the worker is stopping, so it won't answer.
pub fn ask(self: *Proxy, request: Console.Request) bool {
    {
        self.mailbox_mutex.lockUncancelable(self.io);
        defer self.mailbox_mutex.unlock(self.io);
        if (self.stop_requested.load(.acquire) or self.console_request != null) return false;
        self.console_request = request;
    }
    self.scheduler.wake.set(self.io);
    return true;
}

fn answer(self: *Proxy, request: Console.Request) void {
    var found: u32 = 0;
    defer request.reply.finish(self.io, found);
    const now_ms = clock.ms(self.io);
    for (self.links.values()) |link| {
        if (!link.joined or !request.matches(link.name())) continue;
        found += 1;
        switch (request.action) {
            .list, .find => console_log.info("{f} on {s} from {f}, online for {f}", .{ link.who(), self.router.get(link.backend_id).name(), link.address, @import("../log.zig").elapsed(now_ms -| link.created_ms) }),
            .send => link.requestTransfer(.of(request.backend)) catch |err| console_log.warn("Can't move {f} to {s}: {t}", .{ link.who(), self.router.get(.of(request.backend)).name(), err }),
            .kick => {
                console_log.info("Kicked {f}", .{link.who()});
                link.ending("kicked from the console", null);
                _ = link.disconnect(if (request.reason_len == 0) "Kicked by an operator" else request.reasonText());
            },
        }
    }
}

fn drainMailbox(self: *Proxy) void {
    var requests: [mailbox_capacity]TransferRequest = undefined;
    var arrivals: [inbox_capacity]*NetherNet.Connection = undefined;
    var console_request: ?Console.Request = null;
    const count, const arrived = counts: {
        self.mailbox_mutex.lockUncancelable(self.io);
        defer self.mailbox_mutex.unlock(self.io);
        const count = self.mailbox_len;
        @memcpy(requests[0..count], self.mailbox[0..count]);
        self.mailbox_len = 0;
        const arrived = self.inbox_len;
        @memcpy(arrivals[0..arrived], self.inbox[0..arrived]);
        self.inbox_len = 0;
        console_request = self.console_request;
        self.console_request = null;
        break :counts .{ count, arrived };
    };
    for (arrivals[0..arrived]) |connection| self.welcome(connection);
    for (requests[0..count]) |request| self.startTransfer(request);
    if (console_request) |request| self.answer(request);
}

fn startTransfer(self: *Proxy, request: TransferRequest) void {
    const found = self.links.get(request.player) orelse return self.rejectTransfer(request, error.UnknownPlayer);
    found.requestTransfer(request.target) catch |err| self.rejectTransfer(request, err);
}

pub fn message(self: *Proxy, link_id: u64, text: []const u8) void {
    const link = self.links.get(link_id) orelse return;
    link.sendMessage(text) catch |err| log.debug("Plugin message to {f} dropped: {t}", .{ link.who(), err });
}

pub fn packet(self: *Proxy, link_id: u64, target: abi.PacketTarget, bytes: []const u8) abi.Status {
    const link = self.links.get(link_id) orelse return .stale_handle;
    return link.sendPacket(target, bytes);
}

pub fn action(self: *Proxy, link_id: u64, disconnect: bool, backend: u32, reason: []const u8) abi.Status {
    const link = self.links.get(link_id) orelse return .stale_handle;
    if (disconnect) return link.disconnect(reason);
    if (backend == abi.no_backend) return link.resumeLogin();
    if (backend >= self.router.backends.len) return .invalid_argument;
    link.requestTransfer(.of(backend)) catch |err| return switch (err) {
        error.NotManaged => .unsupported,
        error.TransferInProgress, error.TooManyTransfers, error.BackendFull, error.BackendDraining => .busy,
        error.NotInGame, error.AlreadyThere => .too_late,
        error.CanceledByPlugin => .canceled,
        else => .failed,
    };
    return .ok;
}

fn routeNetwork(context: *anyopaque, link_id: u64, target: abi.PacketTarget, out: *abi.NetworkStats) abi.Status {
    const self: *Proxy = @ptrCast(@alignCast(context));
    const link = self.links.get(link_id) orelse return .too_late;
    return link.networkStats(target, out);
}

fn routeGameplay(context: *anyopaque, link_id: u64, query: Handles.Query) abi.Status {
    const self: *Proxy = @ptrCast(@alignCast(context));
    if (query == .backend_health) {
        const request = query.backend_health;
        if (request.backend >= self.router.backends.len) return .invalid_argument;
        request.out.* = .unknown;
        if (self.router.health) |health| {
            if (request.backend >= health.backends.len) return .invalid_argument;
            request.out.* = switch (health.status(.of(request.backend))) {
                .unknown => .unknown,
                .healthy => .healthy,
                .unhealthy => .unhealthy,
            };
        }
        return .ok;
    }
    const link = self.links.get(link_id) orelse return .too_late;
    if (query == .client_data or query == .set_client_data) {
        const managed = link.managed orelse return .unsupported;
        const json = managed.client_data orelse return .too_late;
        if (query == .client_data) {
            query.client_data.* = .of(json);
        } else {
            Managed.checkClientData(self.gpa, query.set_client_data) catch |err| return if (err == error.OutOfMemory) .failed else .invalid_argument;
            const replacement = self.gpa.dupe(u8, query.set_client_data) catch return .failed;
            self.gpa.free(json);
            managed.client_data = replacement;
        }
        return .ok;
    }
    if (query == .login_hints) {
        const managed = link.managed orelse return .unsupported;
        managed.loginHints(query.login_hints) catch return .failed;
        return .ok;
    }
    return link.gameplay(query);
}

fn routeTransfer(context: *anyopaque, link: u64, backend: u32) abi.Status {
    const self: *Proxy = @ptrCast(@alignCast(context));
    self.requestTransfer(link, .of(backend)) catch |err| return switch (err) {
        error.MailboxFull => .busy,
        error.Canceled => .canceled,
    };
    return .ok;
}

fn rejectTransfer(self: *Proxy, request: TransferRequest, err: anyerror) void {
    const target = if (request.target.index() < self.router.backends.len) self.router.get(request.target).name() else "an unknown backend";
    // The requesting plugin already hears why, so this is only for debugging
    if (self.links.get(request.player)) |link|
        transfer_log.debug("Not moving {f} to {s}: {t}", .{ link.who(), target, err })
    else
        transfer_log.debug("Not moving player {d} to {s}: {t}", .{ request.player, target, err });
    self.stats.bump(.transfers_rejected, 1);
}

pub fn stop(self: *Proxy) void {
    self.stop_requested.store(true, .release);
    self.scheduler.wake.set(self.io);
}

pub fn run(self: *Proxy) void {
    self.env.events.proxyStarted();
    while (!self.stop_requested.load(.acquire)) self.turn();
    // Here rather than in stop, so plugins only ever hear from worker tasks
    self.env.events.proxyStopping();
    self.drain();
    self.closeAll();
}

// Players hear why and their last packets get through, a dead peer can't hold this up for long
fn drain(self: *Proxy) void {
    for (self.links.values()) |link| {
        link.ending("proxy shutting down", null);
        _ = link.disconnect("Proxy shutting down");
    }
    const deadline_ms = clock.ms(self.io) + Peer.drain_timeout_ms;
    while (self.links.count() != 0) {
        const now_ms = clock.ms(self.io);
        if (now_ms >= deadline_ms) return;
        self.scheduler.wake.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(@min(deadline_ms - now_ms, 100)), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return,
        };
        self.scheduler.wake.reset();
        for (self.links.values()) |link| self.scheduler.schedule(link);
        self.serviceReady() catch return;
        if (self.scheduler.hasReady()) self.scheduler.wake.set(self.io);
    }
}

fn turn(self: *Proxy) void {
    self.scheduler.wake.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(sweep_interval_ms), .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => {},
        error.Canceled => return self.stop(),
    };
    // Reset before checking, or we could miss a wake
    self.scheduler.wake.reset();
    if (self.stop_requested.load(.acquire)) return;
    const busy_since = clock.ns(self.io);
    defer self.timings.turn.record(Metrics.sinceUs(self.io, busy_since));

    self.drainMailbox();
    {
        const span = trace.zone(@src(), "plugin queue");
        defer span.end();
        self.env.events.drain(self.io, self);
    }
    const now_ms = clock.ms(self.io);
    if (now_ms >= self.next_sweep_ms) {
        self.next_sweep_ms = now_ms + sweep_interval_ms;
        var buffered: u64 = 0;
        for (self.links.values()) |link| {
            link.checkDeadlines(now_ms);
            if (link.session) |*session| buffered += session.buffered();
        }
        self.stats.set(.player_buffered_bytes, buffered);
        self.stats.set(.links_active, self.links.count());
    }
    self.serviceReady() catch return self.stop();
    if (self.scheduler.hasReady()) self.scheduler.wake.set(self.io);
}

fn serviceReady(self: *Proxy) error{Canceled}!void {
    var next = self.scheduler.takeReady();
    while (next) |link| {
        // Grab next first, another task can push this link again once queued is cleared
        next = link.next_ready;
        // A full barrier: a plain store could still be in flight when the poll below finds nothing, and
        // a notify racing with it would then see the link as queued and never wake it
        link.queued.store(false, .seq_cst);
        link.service() catch |err| {
            // Left marked queued, the rest could never be scheduled again
            while (next) |rest| {
                next = rest.next_ready;
                rest.queued.store(false, .seq_cst);
            }
            return err;
        };
        if (link.isFinished() and !link.queued.load(.acquire)) {
            const removed = self.links.swapRemove(link.id);
            std.debug.assert(removed);
            self.retire(link);
        }
    }
}

fn retire(self: *Proxy, link: *Link) void {
    self.admission.leave(self.io, link.address);
    link.destroy();
    self.stats.bump(.links_closed, 1);
    _ = self.players.fetchSub(1, .monotonic);
}

fn welcome(self: *Proxy, connection: *NetherNet.Connection) void {
    self.accept(connection, NetherNet.remoteAddress(connection) orelse unknown_address) catch |err| {
        connection.destroy();
        _ = self.players.fetchSub(1, .monotonic);
        self.stats.bump(.sessions_rejected, 1);
        const now_ms = clock.ms(self.io);
        if (now_ms -| self.rejections_logged_ms >= rejection_log_interval_ms or self.rejections_logged_ms == 0) {
            log.warn("Turning away a connection: {s} ({t}, {d} more since the last warning)", .{ rejection(err), err, self.rejections_unlogged });
            self.rejections_logged_ms = now_ms;
            self.rejections_unlogged = 0;
        } else self.rejections_unlogged += 1;
    };
}

fn rejection(err: anyerror) []const u8 {
    return switch (err) {
        error.ServerFull => "server is full",
        error.TooManyFromAddress => "too many players from one address",
        error.NoBackendAvailable => "no backend is available",
        error.OutOfMemory => "out of memory",
        else => "couldn't set up the session",
    };
}

/// The connection stays with the caller on error.
fn accept(self: *Proxy, connection: *NetherNet.Connection, address: std.Io.net.IpAddress) !void {
    try self.admission.enter(self.io, address);
    errdefer self.admission.leave(self.io, address);
    try self.links.ensureUnusedCapacity(self.gpa, 1);
    const link = try Link.create(&self.env, connection, address);
    errdefer link.release();
    link.id = std.math.add(u64, self.next_player, 1) catch return error.PlayerIdExhausted;
    self.next_player = link.id;
    link.player = self.env.events.connected(.{ .context = self, .worker = self.env.events.worker, .link = link.id, .transfer = routeTransfer, .network = routeNetwork, .gameplay = routeGameplay, .io = self.io }, address, if (self.env.events.plugins != null) link.playerState() else .{});
    if (link.managed) |managed| managed.plugin_player = link.player;

    try link.connect();
    self.links.putAssumeCapacityNoClobber(link.id, link);
    link.watch();
    self.stats.bump(.sessions_accepted, 1);
}

fn closeAll(self: *Proxy) void {
    var arrivals: [inbox_capacity]*NetherNet.Connection = undefined;
    const arrived, const console_request = pending: {
        self.mailbox_mutex.lockUncancelable(self.io);
        defer self.mailbox_mutex.unlock(self.io);
        const arrived = self.inbox_len;
        @memcpy(arrivals[0..arrived], self.inbox[0..arrived]);
        self.inbox_len = 0;
        const request = self.console_request;
        self.console_request = null;
        break :pending .{ arrived, request };
    };
    for (arrivals[0..arrived]) |connection| connection.destroy();
    _ = self.players.fetchSub(@intCast(arrived), .monotonic);
    if (console_request) |request| request.reply.finish(self.io, 0);
    while (self.links.pop()) |entry| self.retire(entry.value);
    self.scheduler.ready.store(null, .monotonic);
}

test "stopped workers reject transfer mailbox submissions without waking" {
    var config: Config = .{ .bind = .{ .ip4 = .loopback(0) }, .max_players = 2 };
    try config.addBackend(null, .{ .ip4 = .loopback(9) });
    var transport: NetherNet = undefined;
    const proxy = try Proxy.create(std.testing.allocator, std.testing.io, config, .{ .transport = &transport });
    defer proxy.destroy();
    for (0..mailbox_capacity) |id| try proxy.requestTransfer(id + 1, .of(0));
    try std.testing.expectError(error.MailboxFull, proxy.requestTransfer(1, .of(0)));
    proxy.stop();
    proxy.scheduler.wake.reset();
    try std.testing.expectError(error.Canceled, proxy.requestTransfer(1, .of(0)));
    try std.testing.expectEqual(abi.Status.canceled, routeTransfer(proxy, 1, 0));
    try std.testing.expectEqual(mailbox_capacity, proxy.mailbox_len);
    proxy.mailbox_len = 0;
    try std.testing.expectError(error.Canceled, proxy.requestTransfer(1, .of(0)));
    try std.testing.expectEqual(@as(usize, 0), proxy.mailbox_len);
    try std.testing.expect(!proxy.scheduler.wake.isSet());
}

test "worker link IDs are retired after failed connections and never wrap" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var config: Config = .{ .bind = .{ .ip4 = .loopback(0) }, .max_players = 2 };
    try config.addBackend(null, .{ .ip4 = .loopback(9) });
    var health: Health = .init(config.backends(), 1000, 100);
    health.markFailed(.of(0));
    var transport: NetherNet = undefined;
    const proxy = try Proxy.create(gpa, io, config, .{ .transport = &transport, .health = &health });
    defer proxy.destroy();
    const connection: *NetherNet.Connection = undefined;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(1) };
    for (1..3) |id| {
        try std.testing.expectError(error.NoBackendAvailable, proxy.accept(connection, address));
        try std.testing.expectEqual(id, proxy.next_player);
        try std.testing.expectEqual(@as(usize, 0), proxy.links.count());
        try std.testing.expectEqual(@as(u32, 0), proxy.admission.active.load(.monotonic));
    }
    proxy.next_player = std.math.maxInt(u64);
    try std.testing.expectError(error.PlayerIdExhausted, proxy.accept(connection, address));
    try std.testing.expectEqual(std.math.maxInt(u64), proxy.next_player);
    try std.testing.expectEqual(@as(u32, 0), proxy.admission.active.load(.monotonic));
}

test "worker link lookup rejects retired IDs after index growth" {
    var proxy: Proxy = undefined;
    proxy.links = .empty;
    defer proxy.links.deinit(std.testing.allocator);
    var links: [64]Link = undefined;
    for (&links, 0..) |*link, i| {
        link.id = (i + 1) * 97;
        link.managed = null;
        try proxy.links.putNoClobber(std.testing.allocator, link.id, link);
    }
    for (&links) |link| try std.testing.expectEqual(abi.Status.unsupported, proxy.packet(link.id, .player, ""));
    const retired = links[16].id;
    try std.testing.expect(proxy.links.swapRemove(retired));
    links[16].id = 100000;
    try proxy.links.putNoClobber(std.testing.allocator, links[16].id, &links[16]);
    try std.testing.expectEqual(abi.Status.stale_handle, proxy.packet(retired, .player, ""));
    try std.testing.expectEqual(abi.Status.stale_handle, proxy.packet(0, .player, ""));
    for (&links) |link| try std.testing.expectEqual(abi.Status.unsupported, proxy.packet(link.id, .player, ""));
    while (proxy.links.pop()) |entry| try std.testing.expectEqual(abi.Status.stale_handle, proxy.packet(entry.key, .player, ""));
}

test "worker link registration cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var config: Config = .{ .bind = .{ .ip4 = .loopback(0) }, .max_players = 2 };
            try config.addBackend(null, .{ .ip4 = .loopback(9) });
            var health: Health = .init(config.backends(), 1000, 100);
            health.markFailed(.of(0));
            var transport: NetherNet = undefined;
            const proxy = try Proxy.create(gpa, std.testing.io, config, .{ .transport = &transport, .health = &health });
            defer proxy.destroy();
            const connection: *NetherNet.Connection = undefined;
            if (proxy.accept(connection, .{ .ip4 = .loopback(1) })) |_| return error.ExpectedRejection else |err| {
                if (err != error.NoBackendAvailable) return err;
            }
            try std.testing.expectEqual(@as(u32, 0), proxy.admission.active.load(.monotonic));
            try std.testing.expectEqual(@as(usize, 0), proxy.links.count());
        }
    }.run, .{});
}
