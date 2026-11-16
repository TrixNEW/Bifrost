const std = @import("std");
const bedwire = @import("bedwire");
const Backend = @import("../backend/Backend.zig");
const Dial = @import("../backend/Dial.zig");
const Health = @import("../backend/Health.zig");
const Router = @import("../backend/Router.zig");
const NetherNet = @import("../net/NetherNet.zig");
const Peer = @import("../net/Peer.zig");
const Observer = @import("../protocol/Observer.zig");
const Managed = @import("../session/Managed.zig");
const Transfer = @import("../transfer/Transfer.zig");
const Events = @import("../plugin/Events.zig");
const abi = @import("../plugin/abi.zig");
const Network = @import("../plugin/Network.zig");
const Handles = @import("../plugin/Handles.zig");
const Budget = @import("Budget.zig");
const PacketQueue = @import("PacketQueue.zig");
const Rate = @import("Rate.zig");
const Scheduler = @import("Scheduler.zig");
const Stats = @import("Stats.zig");
const Metrics = @import("Metrics.zig");
const trace = @import("../trace.zig");

const Link = @This();
const Log = @import("../log.zig");
const log = Log.scoped(.player);
const routing_log = Log.scoped(.routing);
const backend_log = Log.scoped(.backend);
const transfer_log = Log.scoped(.transfer);

// Messages read from each side per turn, so one busy link can't starve the rest
const max_messages_per_turn = 64;
// Each dial can take a full connect timeout; past this only health-checked backends are tried
const max_dial_attempts = 3;
pub const backlog_bytes = NetherNet.backlog_bytes;

pub const Deadlines = struct {
    login_ms: u32 = 30_000,
    resource_packs_ms: u32 = 600_000,
    join_ms: u32 = 120_000,
    slow_player_ms: u32 = 5_000,
};

pub const Stage = enum { login, resource_packs, joining, playing };

pub const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stats: *Stats,
    scheduler: *Scheduler,
    transport: *const NetherNet,
    observer_pool: ?*bedwire.BufferPool,
    auth: Observer.Auth,
    health: ?*Health,
    router: *Router,
    pending_packets: u32,
    pending_bytes: u32,
    budget: ?*Budget = null,
    logins: ?*Rate = null,
    player_bytes_per_second: u32 = 0,
    deadlines: Deadlines = .{},
    managed: ?*Managed.Shared = null,
    transfer: Transfer.Settings = .{ .limits = .{ .dial_ms = 5_000, .phase_ms = 5_000, .total_ms = 15_000 }, .queue_packets = 64, .queue_bytes = 1024 * 1024 },
    transfers: ?*u32 = null,
    max_transfers: u32 = std.math.maxInt(u32),
    next_epoch: ?*Transfer.State.Epoch = null,
    events: Events = .{},
    timings: ?*Metrics.Timings = null,
};

env: *const Env,
// The player's connection, owned by the link
session: ?Peer,
address: std.Io.net.IpAddress,
backend: ?Peer = null,
backend_error: ?anyerror = null,
dial: Dial = .{},
backend_id: Backend.Id = .of(0),
// The backend holding a place for this player in its player count
occupied: ?Backend.Id = null,
dial_task: ?std.Io.Future(void) = null,
tried: Router.Set = .{},
pending: PacketQueue,
observer: ?Observer,
managed: ?*Managed = null,
transfer: ?*Transfer = null,
id: u64 = 0,
player: abi.Player = .{},
announced: bool = false,
// Logged in, or relayed past the login without a name when auth is off
joined: bool = false,
published: abi.PlayerState = .{},
authentication: abi.AuthenticationState = .pending,
network_rates: Network.Rates = .{},
network_backend: ?*NetherNet.Connection = null,
// Can't free the link while it's still on the ready stack
queued: std.atomic.Value(bool) = .init(false),
next_ready: ?*Link = null,
stage: Stage = .login,
stage_since_ms: u64,
backlogged_since_ms: ?u64 = null,
player_closed_ms: ?u64 = null,
dial_started_ns: u64 = 0,
transfer_started_ns: u64 = 0,
created_ms: u64,
name_storage: [max_name_len]u8 = undefined,
name_len: u8 = 0,
// Why the player is leaving, kept from the first cause so later cleanup doesn't overwrite it
end_reason: ?[]const u8 = null,
end_error: ?anyerror = null,

const max_name_len = 32;

/// The link only owns `connection` once `watch` runs.
pub fn create(env: *const Env, connection: *NetherNet.Connection, address: std.Io.net.IpAddress) !*Link {
    const self = try env.gpa.create(Link);
    errdefer env.gpa.destroy(self);
    const managed = if (env.managed) |shared| try Managed.create(env.gpa, shared, address, env.pending_packets, env.pending_bytes) else null;
    errdefer if (managed) |m| m.destroy();
    self.* = .{
        .env = env,
        .session = .init(connection),
        .address = address,
        .pending = .init(env.pending_packets, env.pending_bytes, env.budget),
        .observer = if (env.observer_pool) |pool| try Observer.init(pool, env.player_bytes_per_second) else null,
        .managed = managed,
        .stage_since_ms = nowMs(env.io),
        .created_ms = nowMs(env.io),
    };
    if (managed) |m| m.admission_pending = if (env.events.plugins) |plugins| plugins.admission != null else false;
    return self;
}

pub fn destroy(self: *Link) void {
    self.endTransfer(.player_left);
    self.logEnd();
    self.env.events.disconnected(&self.player);
    self.cancelDial();
    self.dropBackend();
    self.vacate();
    if (self.session) |*session| session.destroy();
    if (self.managed) |managed| managed.destroy();
    self.pending.deinit(self.env.gpa);
    if (self.observer) |*observer| observer.deinit();
    self.env.gpa.destroy(self);
}

/// Hands the player connection to the link; from here on the link is woken whenever it has work.
pub fn watch(self: *Link) void {
    self.session.?.watch(Scheduler.linkNotify(self));
}

/// Gives the connection back to the caller, for links that never got going.
pub fn release(self: *Link) void {
    self.session = null;
    self.ending("not admitted", null);
    self.destroy();
}

/// Records why the player is leaving; the first cause wins.
pub fn ending(self: *Link, reason: []const u8, err: ?anyerror) void {
    if (self.end_reason != null) return;
    self.end_reason = reason;
    self.end_error = err;
}

fn logEnd(self: *const Link) void {
    const reason = self.end_reason orelse "disconnected";
    const lasted = Log.elapsed(nowMs(self.env.io) -| self.created_ms);
    if (!self.joined) {
        if (self.end_error) |err|
            log.debug("Connection from {f} closed before login after {f}: {s} ({t})", .{ self.address, lasted, reason, err })
        else
            log.debug("Connection from {f} closed before login after {f}: {s}", .{ self.address, lasted, reason });
        return;
    }
    const backend = self.env.router.get(self.backend_id).name();
    if (self.end_error) |err|
        log.info("{f} left {s} after {f}: {s} ({t})", .{ self.who(), backend, lasted, reason, err })
    else
        log.info("{f} left {s} after {f}: {s}", .{ self.who(), backend, lasted, reason });
}

/// The player's display name, empty until they logged in.
pub fn name(self: *const Link) []const u8 {
    return self.name_storage[0..self.name_len];
}

/// The player's name once known, their link id before that.
pub fn who(self: *const Link) Who {
    return .{ .link = self };
}

pub const Who = struct {
    link: *const Link,

    pub fn format(self: Who, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const link = self.link;
        if (link.name_len != 0) return w.writeAll(link.name_storage[0..link.name_len]);
        try w.print("Player {d}", .{link.id});
    }
};

fn logJoin(self: *Link) void {
    if (self.joined) return;
    self.joined = true;
    log.info("{f} joined {s} from {f}", .{ self.who(), self.env.router.get(self.backend_id).name(), self.address });
}

pub fn connect(self: *Link) (error{NoBackendAvailable} || std.Io.ConcurrentError)!void {
    defer self.publishState();
    std.debug.assert(self.dial_task == null and self.backend == null);
    const span = trace.zone(@src(), "routing");
    const picked = self.env.router.claim(self.tried, self.tried.count() >= max_dial_attempts);
    span.end();
    const id = picked orelse return error.NoBackendAvailable;
    self.occupied = id;
    self.tried.add(id);
    self.backend_id = id;
    self.env.events.backendSelected(self.player, id.index());
    self.dial = .{};
    self.dial_started_ns = Metrics.nowNs(self.env.io);
    const backend = self.env.router.get(id);
    routing_log.debug("{f} -> {f}, attempt {d}", .{ self.who(), backend.*, self.tried.count() });
    self.dial_task = try self.env.io.concurrent(Dial.run, .{ &self.dial, self.env.transport, backend.address, Scheduler.linkNotify(self) });
}

pub fn isFinished(self: *const Link) bool {
    return self.dial_task == null and self.session == null and self.backend == null;
}

pub fn forwardToBackend(self: *Link, message: NetherNet.Message) !void {
    defer self.publishState();
    const payload = message.data;
    if (message.reliability != .reliable) {
        // Bedwire only speaks the reliable channel, so only passthrough can carry these, and only once the Login is through
        if (self.managed == null and !self.observer.?.watching) if (self.backend) |*backend| return backend.sendAs(payload, .unreliable);
        self.env.stats.bump(.unreliable_dropped, 1);
        return;
    }
    if (self.managed) |managed| {
        if (self.backend == null and self.dial_task == null and !managed.orphaned) return error.BackendClosed;
        managed.fromPlayer(self.ends(), payload) catch |err| {
            // A send can find the old backend gone before reading it does
            if (self.backend) |*backend| if (!backend.connected() and self.orphan(err)) return;
            if (managed.identity == null and managed.player_phase == .login) self.authentication = if (err == error.OutOfMemory or err == error.ServerBusy) .unavailable else .rejected;
            return err;
        };
        if (!self.announced) if (managed.identity) |identity| self.announce(identity);
        return;
    }
    const observer = &self.observer.?;
    if (observer.watching and self.observe(observer, .client_to_server, payload).rejects()) return error.LoginRejected;
    if (observer.identity) |identity| {
        self.announce(identity);
        observer.dropIdentity();
    }
    if (self.backend) |*backend| {
        try backend.send(payload);
        self.env.stats.bump(.bytes_to_backend, payload.len);
        self.env.stats.bump(.messages_to_backend, 1);
    } else if (self.dial_task != null) {
        try self.pending.push(self.env.gpa, payload);
    } else return error.BackendClosed;
}

pub fn resumeLogin(self: *Link) abi.Status {
    const managed = self.managed orelse return .unsupported;
    if (self.session == null) return .stale_handle;
    if (!self.announced or managed.identity == null or !managed.admission_pending) return .too_late;
    managed.admission_pending = false;
    if (managed.player_phase == .ready and managed.upstream.phase == .waiting_for_login) {
        managed.loginUpstream(&managed.upstream, managed.upstreamContext(self.ends(), if (self.backend) |*backend| backend else return .too_late)) catch return .failed;
    }
    return .ok;
}

pub fn sendMessage(self: *Link, text: []const u8) !void {
    const managed = self.managed orelse return error.NotManaged;
    if (self.session == null) return error.NotInGame;
    const session = &self.session.?;
    if (!session.open() or !managed.inGame()) return error.NotInGame;
    try managed.sendText(self.ends(), text);
}

pub fn disconnect(self: *Link, reason: []const u8) abi.Status {
    if (self.session == null) return .stale_handle;
    if (!self.session.?.open()) return .too_late;
    var status: abi.Status = .ok;
    if (reason.len != 0) if (self.managed) |managed| {
        managed.sendDisconnect(self.ends(), reason) catch {
            status = .failed;
        };
    };
    self.closeSession();
    if (self.env.events.plugins) |plugins| plugins.handles.invalidatePackets(self.player);
    return status;
}

pub fn networkStats(self: *Link, target: abi.PacketTarget, out: *abi.NetworkStats) abi.Status {
    if (self.session == null) return .stale_handle;
    const session = &self.session.?;
    if (!session.open()) return .too_late;
    const now_ms = @import("../plugin/Packets.zig").now(self.env.io) / std.time.ns_per_ms;
    switch (target) {
        .player => out.* = Network.snapshot(session, now_ms),
        .backend => {
            if (self.backend == null) return .too_late;
            const backend = &self.backend.?;
            if (!backend.open()) return .too_late;
            if (self.network_backend != backend.connection) {
                self.network_backend = backend.connection;
                self.network_rates = .{};
            }
            out.* = Network.snapshot(backend, now_ms);
            self.network_rates.sample(.of(backend.connection), out);
        },
        else => return .invalid_argument,
    }
    return .ok;
}

pub fn gameplay(self: *Link, query: Handles.Query) abi.Status {
    if (self.session == null) return .stale_handle;
    const session = &self.session.?;
    if (!session.open()) return .too_late;
    const managed = self.managed orelse return .unsupported;
    const now_ms = @import("../plugin/Packets.zig").now(self.env.io) / std.time.ns_per_ms;
    return managed.gameplay.answer(query, now_ms, managed.client_state.effects);
}

pub fn playerState(self: *const Link) abi.PlayerState {
    var state: abi.PlayerState = .{
        .backend = if (self.tried.count() != 0) @intCast(self.backend_id.index()) else abi.no_backend,
        .authentication = if (self.authentication != .pending) self.authentication else if (self.env.auth == .off) .disabled else .pending,
        .mode = if (self.managed != null) .managed else .passthrough,
    };
    if (self.managed) |managed| {
        if (managed.identity != null) state.authentication = .authenticated;
        state.phase = switch (managed.player.state) {
            .transport_ready, .network_settings => .settings,
            .authenticating => .login,
            .encrypted_handshake => .handshake,
            .resource_packs => .resource_packs,
            .waiting_for_start_game, .spawn_ready => .joining,
            .in_game => .in_game,
            .closing => .closing,
            .disconnected => .disconnected,
        };
    }
    if (self.observer) |observer| if (observer.verified) {
        state.authentication = .authenticated;
    };
    if (self.transfer) |transfer| {
        state.transfer = transfer.pluginState();
        if (transfer.state.phase.committed()) state.backend = @intCast(transfer.target.index());
    }
    if (self.session) |session| {
        if (session.closing_since_ms != null) {
            state.connection = .closing;
            state.phase = .closing;
        }
    } else {
        state.connection = .disconnected;
        state.phase = .disconnected;
    }
    return state;
}

fn publishState(self: *Link) void {
    if (self.env.events.plugins == null or self.player.id == 0) return;
    const state = self.playerState();
    if (std.meta.eql(state, self.published)) return;
    self.published = state;
    self.env.events.stateChanged(self.player, state);
}

pub fn sendPacket(self: *Link, target: abi.PacketTarget, bytes: []const u8) abi.Status {
    const managed = self.managed orelse return .unsupported;
    if (self.session == null) return .stale_handle;
    const session = &self.session.?;
    if (!session.open()) return .too_late;
    if (self.transfer != null) return .busy;
    if (self.backend == null) return .too_late;
    const backend = &self.backend.?;
    if (self.backend_error != null or !managed.inGame()) return .too_late;
    if ((if (target == .player) session else backend).backlogged(backlog_bytes)) return .busy;
    managed.inject(self.ends(), target, bytes) catch |err| {
        if (err == error.NotInGame) return .too_late;
        self.fail(err);
        return .failed;
    };
    return .ok;
}

fn announce(self: *Link, identity: bedwire.Identity) void {
    self.announced = true;
    var len = @min(identity.display_name.len, max_name_len);
    // Cut on a character boundary
    if (len < identity.display_name.len) while (len > 0 and identity.display_name[len] & 0xc0 == 0x80) : (len -= 1) {};
    @memcpy(self.name_storage[0..len], identity.display_name[0..len]);
    self.name_len = @intCast(len);
    self.logJoin();
    log.debug("{f} has xuid {s}, {s}", .{ self.who(), identity.xuid, if (identity.online) "signed in to Xbox" else "offline" });
    self.published = self.playerState();
    const decision = self.env.events.authenticated(self.player, identity.display_name, identity.xuid, identity.uuid, identity.online, self.published);
    if (decision.action == .cancel) {
        self.ending("rejected by a plugin", null);
        _ = self.disconnect("Login rejected");
        return;
    }
    if (decision.action != .hold_login) {
        _ = self.resumeLogin();
    }
}

fn playerGone(self: *Link) void {
    self.endTransfer(.player_left);
    self.env.events.disconnected(&self.player);
    if (self.session) |*session| session.destroy();
    self.session = null;
    self.cancelDial();
    // What the player sent last is still on its way to the backend
    if (self.backend) |*backend| backend.closeSoon(nowMs(self.env.io));
    self.pending.clear(self.env.gpa);
    self.env.scheduler.schedule(self);
}

pub fn service(self: *Link) error{Canceled}!void {
    defer self.publishState();
    if (self.dial_task) |*task| if (self.dial.finished()) |result| {
        task.await(self.env.io);
        self.dial_task = null;
        self.adopt(result);
    };
    if (self.transfer) |transfer| if (self.session) |*session| switch (try transfer.service(self.transferHost(session))) {
        .running => {},
        .finished, .abandoned => self.endTransfer(null),
        .rolled_back => {
            self.endTransfer(null);
            // The old backend left while the transfer was trying, so there's nothing to roll back to
            if (self.backend == null and self.managed.?.orphaned) {
                self.ending("the old backend left and the transfer failed", null);
                if (self.managed.?.held_kick == null) {
                    _ = self.disconnect("Lost connection to the server");
                } else {
                    self.managed.?.releaseKick(self.ends()) catch {};
                    self.closeSession();
                }
            }
        },
        .disconnect => {
            self.endTransfer(null);
            self.closeSession();
        },
    };
    self.pumpPlayer();
    self.pumpBackend();
    self.followRedirect();
    // Syncing the client can finish a transfer, and only the top of a turn ends one
    if (self.transfer) |transfer| if (transfer.result != .running) self.env.scheduler.schedule(self);
}

fn pumpPlayer(self: *Link) void {
    if (self.session == null) return;
    const session = &self.session.?;
    if (session.closing_since_ms != null) {
        if (session.drained(nowMs(self.env.io))) self.playerGone() else self.discard(session);
        return;
    }
    const span = trace.zone(@src(), "player io");
    defer span.end();
    for (0..max_messages_per_turn) |_| {
        // The backend's own window then slows the player down
        if (self.backend) |*backend| if (backend.backlogged(backlog_bytes)) return;
        const message = (session.next() catch return self.playerGone()) orelse return;
        self.forwardToBackend(message) catch |err| {
            log.debug("Dropping {f}: {t}", .{ self.who(), err });
            self.ending(switch (err) {
                error.LoginRejected => "login rejected",
                error.BackendClosed => "backend connection lost",
                error.ServerBusy => "too many logins at once, told to retry",
                else => switch (self.authentication) {
                    .rejected => "login rejected",
                    .unavailable => "login couldn't be verified",
                    else => "bad or unexpected packet",
                },
            }, err);
            _ = self.disconnect("");
            return;
        };
        if (self.session == null or self.session.?.closing_since_ms != null) return;
    }
    self.env.scheduler.schedule(self);
}

fn pumpBackend(self: *Link) void {
    if (self.backend == null) return;
    const backend = &self.backend.?;
    if (backend.closing_since_ms != null) {
        if (backend.drained(nowMs(self.env.io))) self.dropBackend() else self.discard(backend);
        return;
    }
    const span = trace.zone(@src(), "backend io");
    defer span.end();
    var drained = false;
    var paused = false;
    for (0..max_messages_per_turn) |_| {
        if (self.stalled()) {
            paused = true;
            break;
        }
        const message = (backend.next() catch |err| {
            // A backend that sends the player on and then closes is common, so the move starts before the close counts
            self.followRedirect();
            if (self.orphan(err)) return;
            self.ending("backend closed the connection", err);
            return self.fail(err);
        }) orelse {
            drained = true;
            break;
        };
        self.onBackendMessage(message);
        if (self.backend_error != null) break;
    }
    if (self.backend_error) |err| {
        self.backend_error = null;
        return self.fail(err);
    }
    if (self.transfer) |transfer| if (self.session) |*session| transfer.syncClient(self.transferHost(session)) catch |err| return self.fail(err);
    if (paused and self.stalled()) return self.pause();
    self.backlogged_since_ms = null;
    if (!drained) self.env.scheduler.schedule(self);
}

// A backend's Transfer to another backend waits for any transfer underway and for the player to be in game. A kick
// held back for it reaches the player once no move is coming.
fn followRedirect(self: *Link) void {
    const managed = self.managed orelse return;
    if (self.transfer != null) return;
    const session = if (self.session) |*session| session else return;
    if (!session.open()) return;
    if (managed.redirect) |target| if (managed.inGame()) {
        managed.redirect = null;
        if (self.requestTransfer(target)) {
            self.env.stats.bump(.backend_redirects, 1);
            return;
        } else |err| transfer_log.debug("{f}'s backend asked to move them to {s}, which can't happen now: {t}", .{ self.who(), self.env.router.get(target).name(), err });
    };
    managed.releaseKick(self.ends()) catch |err| self.fail(err);
}

// Keeps reading a closing peer, or its sends stall and our own close can't finish
fn discard(self: *Link, peer: *Peer) void {
    for (0..max_messages_per_turn) |_| {
        _ = (peer.next() catch return) orelse return;
    }
    self.env.scheduler.schedule(self);
}

// The backend isn't read until the player catches up, so its own flow control slows it down.
// The player's drained callback wakes the link again, and so does the sweep.
fn pause(self: *Link) void {
    if (self.backlogged_since_ms != null) return;
    self.backlogged_since_ms = nowMs(self.env.io);
    self.env.stats.bump(.backlog_pauses, 1);
}

// Not reading the backend lets its own flow control slow it down.
fn stalled(self: *Link) bool {
    if (self.playerBacklogged()) return true;
    const managed = self.managed orelse return false;
    const hold = managed.hold orelse return false;
    return hold.nearlyFull();
}

pub fn playerBacklogged(self: *Link) bool {
    if (self.session == null) return false;
    const session = &self.session.?;
    if (session.closing_since_ms != null) return false;
    // Resuming at half the mark keeps a busy player from flapping
    const shift: u1 = @intFromBool(self.backlogged_since_ms != null);
    return session.backlogged(@as(usize, backlog_bytes) >> shift);
}

// Worker only, once a second
pub fn sampleTransport(self: *Link) u64 {
    if (self.session == null) return 0;
    const session = &self.session.?;
    return session.buffered();
}

pub fn checkDeadlines(self: *Link, now_ms: u64) void {
    if (self.backend) |backend| if (backend.closing_since_ms != null) self.env.scheduler.schedule(self);
    if (self.session == null) return;
    const session = &self.session.?;
    if (session.closing_since_ms != null) return self.env.scheduler.schedule(self);
    const deadlines = self.env.deadlines;
    // Reading is what notices a player leaving, and a backed up backend holds reading off
    if (!session.connected()) {
        const since = self.player_closed_ms orelse now_ms;
        self.player_closed_ms = since;
        if (now_ms -| since >= deadlines.slow_player_ms) return self.playerGone();
    }
    if (self.backlogged_since_ms) |since| {
        if (now_ms -| since >= deadlines.slow_player_ms) {
            self.env.stats.bump(.slow_players, 1);
            self.ending("connection too slow to keep up", null);
            _ = self.disconnect("Connection too slow");
            return;
        }
        self.env.scheduler.schedule(self);
    }
    const stage = self.currentStage();
    if (stage != self.stage) {
        self.stage = stage;
        self.stage_since_ms = now_ms;
        return;
    }
    const limit_ms = switch (stage) {
        .login => deadlines.login_ms,
        .resource_packs => deadlines.resource_packs_ms,
        .joining => deadlines.join_ms,
        .playing => return,
    };
    if (now_ms -| self.stage_since_ms < limit_ms) return;
    const stats = self.env.stats;
    switch (stage) {
        .login => stats.bump(.login_timeouts, 1),
        .resource_packs => stats.bump(.resource_pack_timeouts, 1),
        .joining, .playing => stats.bump(.join_timeouts, 1),
    }
    self.ending(switch (stage) {
        .login => "timed out logging in",
        .resource_packs => "timed out downloading resource packs",
        .joining, .playing => "timed out joining",
    }, null);
    _ = self.disconnect("Timed out");
}

fn currentStage(self: *const Link) Stage {
    if (self.managed) |managed| {
        if (managed.upstream.phase != .ready) return .login;
        return switch (managed.player.state) {
            .transport_ready, .network_settings, .authenticating, .encrypted_handshake => .login,
            .resource_packs => .resource_packs,
            .waiting_for_start_game, .spawn_ready => .joining,
            .in_game, .closing, .disconnected => .playing,
        };
    }
    if (self.observer) |observer| if (observer.watching) return .login;
    return .playing;
}

fn nowMs(io: std.Io) u64 {
    return @intCast(@divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}

fn observe(self: *Link, observer: *Observer, direction: bedwire.TapDirection, payload: []const u8) Observer.Event {
    const event = observer.observe(.{
        .gpa = self.env.gpa,
        .io = self.env.io,
        .auth = self.env.auth,
        .now_ms = nowMs(self.env.io),
        .logins = self.env.logins,
        .transport_key = if (self.session) |*session| session.identityKey() else null,
    }, direction, payload);
    const stats = self.env.stats;
    switch (event) {
        .none => {},
        .logged_in => {
            stats.bump(.logins_observed, 1);
            self.logJoin();
        },
        .gave_up => {
            stats.bump(.observer_gave_up, 1);
            self.logJoin();
        },
        .login_verified => {
            stats.bump(.logins_observed, 1);
            stats.bump(.logins_verified, 1);
        },
        .login_rejected => {
            self.ending("login rejected", null);
            self.authentication = .rejected;
            stats.bump(.logins_rejected, 1);
        },
        .auth_unavailable => {
            self.ending("login couldn't be verified", null);
            self.authentication = .unavailable;
            stats.bump(.auth_unavailable, 1);
        },
        .login_throttled => {
            self.ending("too many logins at once, told to retry", null);
            self.authentication = .unavailable;
            stats.bump(.logins_throttled, 1);
        },
        .flooded => {
            self.ending("sent too much data", null);
            stats.bump(.player_floods, 1);
        },
    }
    return event;
}

fn adopt(self: *Link, result: Dial.Result) void {
    const took = Log.elapsed(Metrics.sinceUs(self.env.io, self.dial_started_ns) / std.time.us_per_ms);
    const backend = self.env.router.get(self.backend_id);
    const connection = result catch |err| {
        self.env.stats.bump(.backend_failures, 1);
        if (err == error.Canceled) return self.closeSession();
        const warn = if (self.env.health) |health| health.warnDial(self.backend_id, nowMs(self.env.io)) else true;
        if (warn)
            backend_log.warn("Can't reach {f}: {s} ({t}, {f})", .{ backend.*, NetherNet.describe(err), err, took })
        else
            backend_log.debug("Can't reach {f} for {f}: {s} ({t}, {f})", .{ backend.*, self.who(), NetherNet.describe(err), err, took });
        self.env.router.dialFailed(self.env.io, self.backend_id);
        self.vacate();
        if (self.session == null) return;
        self.connect() catch |retry_err| {
            self.ending("no backend available", retry_err);
            self.closeSession();
        };
        return;
    };
    backend_log.debug("{f} connected to {s} in {f}", .{ self.who(), backend.name(), took });
    self.backend = .init(connection);
    self.backend.?.watch(Scheduler.linkNotify(self));
    self.network_rates = .{};
    self.env.stats.bump(.backends_connected, 1);
    if (self.env.timings) |timings| timings.dial.record(Metrics.sinceUs(self.env.io, self.dial_started_ns));
    if (self.session == null) return self.dropBackend();
    if (self.managed) |managed| return managed.backendConnected(self.ends()) catch |err| self.fail(err);
    self.flushPending() catch |err| self.fail(err);
}

pub fn requestTransfer(self: *Link, requested: Backend.Id) !void {
    defer self.publishState();
    self.startTransfer(requested) catch |err| {
        self.env.events.stateChanged(self.player, self.playerState());
        self.env.events.transferEnded(self.player, self.backend_id.index(), requested.index(), .rejected);
        return err;
    };
}

fn startTransfer(self: *Link, requested: Backend.Id) !void {
    const managed = self.managed orelse return error.NotManaged;
    if (self.transfer != null) return error.TransferInProgress;
    if (self.session == null) return error.NotInGame;
    const session = &self.session.?;
    if (!session.open()) return error.NotInGame;
    if (self.backend == null or !managed.inGame()) return error.NotInGame;
    const decision = self.env.events.transferRequested(self.player, self.backend_id.index(), requested.index());
    const target: Backend.Id = switch (decision.action) {
        .cancel => return error.CanceledByPlugin,
        .redirect => if (decision.backend < self.env.router.backends.len) .of(decision.backend) else return error.UnknownBackend,
        else => requested,
    };
    if (target.index() >= self.env.router.backends.len) return error.UnknownBackend;
    if (target == self.backend_id) return error.AlreadyThere;
    if (self.env.transfers) |count| if (count.* >= self.env.max_transfers) return error.TooManyTransfers;
    try self.env.router.claimTarget(target);
    errdefer self.env.router.release(target);
    const epoch = self.env.next_epoch.?;
    epoch.* +%= 1;
    self.transfer = try Transfer.create(self.transferHost(session), target, self.env.router.get(target).address, epoch.*, self.env.transfer);
    managed.moving = true;
    if (self.env.transfers) |count| count.* += 1;
    self.transfer_started_ns = Metrics.nowNs(self.env.io);
    self.env.scheduler.schedule(self);
}

fn transferHost(self: *Link, session: *Peer) Transfer.Host {
    return .{
        .gpa = self.env.gpa,
        .io = self.env.io,
        .stats = self.env.stats,
        .transport = self.env.transport,
        .managed = self.managed.?,
        .player = session,
        .notify = Scheduler.linkNotify(self),
        .backend = &self.backend,
        .events = self.env.events,
        .source_backend = @intCast(self.backend_id.index()),
    };
}

fn endTransfer(self: *Link, event: ?Transfer.State.Event) void {
    const transfer = self.transfer orelse return;
    const source = self.backend_id;
    self.transfer = null;
    if (self.managed) |managed| managed.moving = false;
    if (self.env.transfers) |count| count.* -= 1;
    if (event) |cause| transfer.end(self.env.io, self.env.stats, cause);
    if (transfer.outcome == .committed) if (self.env.timings) |timings| timings.transfer.record(Metrics.sinceUs(self.env.io, self.transfer_started_ns));
    if (transfer.state.phase.committed()) {
        self.vacate();
        self.occupied = transfer.target;
        self.backend_id = transfer.target;
        self.network_rates = .{};
    } else self.env.router.release(transfer.target);
    self.logTransfer(transfer, source, event);
    self.publishState();
    self.env.events.transferEnded(self.player, source.index(), transfer.target.index(), failure(transfer));
    transfer.destroy(self.env.gpa, self.env.io);
}

fn logTransfer(self: *const Link, transfer: *const Transfer, source: Backend.Id, event: ?Transfer.State.Event) void {
    const from = self.env.router.get(source).name();
    const to = self.env.router.get(transfer.target).name();
    const took = Log.elapsed(Metrics.sinceUs(self.env.io, self.transfer_started_ns) / std.time.us_per_ms);
    const why: []const u8 = switch (failure(transfer)) {
        .none => return transfer_log.info("{f} moved {s} -> {s} in {f}", .{ self.who(), from, to, took }),
        .incompatible_content => "the target's resource packs don't match",
        .failed_after_commit => "the target failed after the switch",
        .timed_out => "timed out",
        else => if (event == .source_failed) "the current backend failed" else "the target couldn't be reached or refused the player",
    };
    if (event == .player_left or event == .shutdown)
        transfer_log.debug("{f} left while moving {s} -> {s}", .{ self.who(), from, to })
    else
        transfer_log.warn("{f} couldn't move {s} -> {s} after {f}: {s}", .{ self.who(), from, to, took, why });
}

fn failure(transfer: *const Transfer) abi.TransferFailure {
    return switch (transfer.outcome orelse return .failed_before_commit) {
        .committed => .none,
        .failed_before_commit => if (transfer.mismatch != null) .incompatible_content else .failed_before_commit,
        .failed_after_commit => .failed_after_commit,
        .timed_out => .timed_out,
    };
}

fn ends(self: *Link) Managed.Ends {
    return .{ .io = self.env.io, .stats = self.env.stats, .player = &self.session.?, .backend = if (self.backend) |*backend| backend else null };
}

// Errors wait for the turn to end, so the rest of the batch isn't half handled
fn onBackendMessage(self: *Link, message: NetherNet.Message) void {
    const span = trace.zone(@src(), "backend packet");
    defer span.end();
    defer self.publishState();
    if (self.session == null) return;
    const session = &self.session.?;
    // A gone player can't take this, but what it sent last still drains to the backend.
    if (!session.open()) return;
    const payload = message.data;
    if (message.reliability != .reliable) {
        if (self.managed == null) session.sendAs(payload, .unreliable) catch self.closeSession() else self.env.stats.bump(.unreliable_dropped, 1);
        return;
    }
    if (self.managed) |managed| return managed.fromBackend(self.ends(), payload) catch |err| {
        log.debug("Managed session of {f} failed on a backend packet: {t}", .{ self.who(), err });
        self.ending("backend sent something the proxy can't handle", err);
        self.backend_error = err;
    };
    const observer = &self.observer.?;
    if (observer.watching and self.observe(observer, .server_to_client, payload).rejects()) {
        self.backend_error = error.LoginRejected;
        return;
    }
    // The player is leaving, not the backend, so what it already sent can still drain to the backend
    session.send(payload) catch return self.closeSession();
    self.env.stats.bump(.bytes_to_player, payload.len);
    self.env.stats.bump(.messages_to_player, 1);
}

fn flushPending(self: *Link) !void {
    defer self.pending.clear(self.env.gpa);
    const backend = &self.backend.?;
    for (self.pending.items()) |packet| {
        try backend.send(packet);
        self.env.stats.bump(.bytes_to_backend, packet.len);
        self.env.stats.bump(.messages_to_backend, 1);
    }
}

// The old backend closing mid-transfer leaves the player waiting on the target instead of ending the session
fn orphan(self: *Link, err: anyerror) bool {
    const transfer = self.transfer orelse return false;
    const managed = self.managed orelse return false;
    if (transfer.state.phase.committed()) return false;
    transfer_log.info("{s} closed while {f} was moving to {s}; the transfer carries on ({t})", .{ self.env.router.get(self.backend_id).name(), self.who(), self.env.router.get(transfer.target).name(), err });
    self.dropBackend();
    managed.orphaned = true;
    return true;
}

fn cancelDial(self: *Link) void {
    var task = self.dial_task orelse return;
    self.dial_task = null;
    self.dial.cancel(&task, self.env.io);
}

fn fail(self: *Link, err: anyerror) void {
    log.debug("Closing {f}: {t}", .{ self.who(), err });
    self.ending("session failed", err);
    const committed = if (self.transfer) |transfer| transfer.state.phase.committed() else false;
    self.endTransfer(if (committed) .target_failed else .source_failed);
    self.dropBackend();
    self.closeSession();
}

fn closeSession(self: *Link) void {
    if (self.session) |*session| session.closeSoon(nowMs(self.env.io));
    self.publishState();
    self.env.scheduler.schedule(self);
}

fn dropBackend(self: *Link) void {
    var backend = self.backend orelse return;
    self.backend = null;
    backend.destroy();
    self.pending.clear(self.env.gpa);
    self.vacate();
}

fn vacate(self: *Link) void {
    const id = self.occupied orelse return;
    self.occupied = null;
    self.env.router.release(id);
}
