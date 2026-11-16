const std = @import("std");
const abi = @import("abi.zig");
const Plugins = @import("Plugins.zig");
const Handles = @import("Handles.zig");
const Packets = @import("Packets.zig");
const Work = @import("Work.zig");
const injection = @import("injection.zig");
const clock = @import("../clock.zig");

const log = @import("../log.zig").scoped(.plugin);
const Loaded = Plugins.Loaded;
const max_command_len = Plugins.max_command_len;
const max_description_len = Plugins.max_description_len;
const reserveMessage = Plugins.reserveMessage;
const reserveInjection = Plugins.reserveInjection;

/// The table a plugin calls the proxy through. Every entry gets the plugin's own `Loaded` as its context.
pub fn table(loaded: *Loaded) abi.Host {
    return .{
        .context = loaded,
        .log = hostLog,
        .subscribe = hostSubscribe,
        .backend_count = hostBackendCount,
        .backend_name = hostBackendName,
        .player_name = hostPlayerName,
        .transfer = hostTransfer,
        .worker_count = hostWorkerCount,
        .subscribe_packet = hostSubscribePacket,
        .register_command = hostRegisterCommand,
        .spawn_task = hostSpawnTask,
        .send_message = hostSendMessage,
        .post = hostPost,
        .register_command_info = hostRegisterCommandInfo,
        .set_description = hostSetDescription,
        .decode_packet = Packets.decodePacket,
        .encode_packet = Packets.encodePacket,
        .send_packet = hostSendPacket,
        .player_info = hostPlayerInfo,
        .network_stats = hostNetworkStats,
        .disconnect = hostDisconnect,
        .request_transfer = hostRequestTransfer,
        .player_gameplay = hostPlayerGameplay,
        .find_entity = hostFindEntity,
        .list_entities = hostListEntities,
        .resume_login = hostResumeLogin,
        .login_hints = hostLoginHints,
        .backend_health = hostBackendHealth,
        .client_data = hostClientData,
        .set_client_data = hostSetClientData,
        .find_player = hostFindPlayer,
        .list_players = hostListPlayers,
    };
}

fn hostFindPlayer(context: *anyopaque, name_or_xuid: abi.Str, out: ?*abi.Player) callconv(.c) abi.Status {
    const result = out orelse return .invalid_argument;
    const text = Plugins.input(name_or_xuid, Handles.max_name_len) orelse return .invalid_argument;
    result.* = from(context).owner.handles.lookup(text) orelse return .not_found;
    return .ok;
}

fn hostListPlayers(context: *anyopaque, out: ?[*]abi.Player, capacity: usize, total: ?*usize) callconv(.c) abi.Status {
    const count = total orelse return .invalid_argument;
    if (out == null and capacity != 0) return .invalid_argument;
    count.* = from(context).owner.handles.list(if (out) |players| players[0..capacity] else &.{});
    return .ok;
}

fn from(context: *anyopaque) *Loaded {
    return @ptrCast(@alignCast(context));
}

fn hostLog(context: *anyopaque, level: abi.LogLevel, message: abi.Str) callconv(.c) void {
    const loaded = from(context);
    const now_ns = clock.ns(std.Options.debug_io);
    const dropped = loaded.admitLog(@truncate(now_ns / std.time.ns_per_s)) orelse return;
    const text = message.slice();
    const name = if (loaded.ready.load(.acquire)) loaded.label() else "A loading plugin";
    if (dropped != 0) log.warn("{s} logged more than {d} lines a second; {d} were dropped", .{ name, Plugins.max_log_lines_per_second, dropped });
    switch (level) {
        .err => log.err("{s}: {s}", .{ name, text }),
        .warn => log.warn("{s}: {s}", .{ name, text }),
        .info => log.info("{s}: {s}", .{ name, text }),
        else => log.debug("{s}: {s}", .{ name, text }),
    }
}

fn hostSubscribe(context: *anyopaque, kind: abi.EventKind, callback: ?abi.EventFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    if (!Work.hosted) return .wrong_thread;
    if (owner.initializing.load(.acquire) != loaded) return .too_late;
    if (@backingInt(kind) >= abi.EventKind.count) return .invalid_argument;
    const subscriber: Plugins.Subscriber = .{ .loaded = loaded, .callback = callback orelse return .invalid_argument, .user = user };
    for (owner.pending.items) |item| if (item.kind == kind and std.meta.eql(item.subscriber, subscriber)) return .invalid_argument;
    owner.pending.append(owner.gpa, .{ .kind = kind, .subscriber = subscriber }) catch return .failed;
    return .ok;
}

fn hostSetDescription(context: *anyopaque, description: abi.Str) callconv(.c) abi.Status {
    const loaded = from(context);
    if (!Work.hosted) return .wrong_thread;
    if (loaded.owner.initializing.load(.acquire) != loaded) return .too_late;
    const bytes = Plugins.input(description, max_description_len) orelse return .invalid_argument;
    if (!Plugins.printable(bytes)) return .invalid_argument;
    @memcpy(loaded.metadata.description_buffer[0..bytes.len], bytes);
    loaded.metadata.description_len = @intCast(bytes.len);
    return .ok;
}

fn hostSubscribePacket(context: *anyopaque, direction: abi.Direction, id: u32, phase: abi.PacketPhase, flags: abi.PacketFlags, callback: ?abi.PacketFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    if (!Work.hosted) return .wrong_thread;
    if (owner.initializing.load(.acquire) != loaded) return .too_late;
    if (!owner.options.packets) return .unsupported;
    if (@backingInt(direction) > 1 or id >= Packets.id_count or @backingInt(phase) > 2) return .invalid_argument;
    if (@as(u32, @bitCast(flags)) & ~@as(u32, @bitCast(abi.PacketFlags.supported)) != 0) return .invalid_argument;
    const packet_callback = callback orelse return .invalid_argument;
    for (owner.pending_packets.items) |item| {
        if (item.direction == direction and item.id == id and item.subscriber.callback == packet_callback and item.subscriber.user == user) return .invalid_argument;
    }
    owner.pending_packets.append(owner.gpa, .{ .direction = direction, .id = @intCast(id), .subscriber = .{
        .callback = packet_callback,
        .user = user,
        .phase = phase,
        .validated = flags.validated,
        .fields = flags.fields,
        .name = "",
        .metrics = &.{},
    } }) catch return .failed;
    return .ok;
}

fn hostRegisterCommand(context: *anyopaque, name: abi.Str, callback: ?abi.CommandFn, user: ?*anyopaque) callconv(.c) abi.Status {
    return registerCommand(from(context), &.{ .name = name, .callback = callback, .user = user });
}

fn hostRegisterCommandInfo(context: *anyopaque, info: ?*const abi.CommandInfo) callconv(.c) abi.Status {
    const command = info orelse return .invalid_argument;
    if (command.struct_size < @sizeOf(abi.CommandInfo)) return .invalid_argument;
    return registerCommand(from(context), command);
}

fn registerCommand(loaded: *Loaded, info: *const abi.CommandInfo) abi.Status {
    const owner = loaded.owner;
    if (!Work.hosted) return .wrong_thread;
    if (owner.initializing.load(.acquire) != loaded) return .too_late;
    if (!owner.options.packets) return .unsupported;
    const text = Plugins.input(info.name, max_command_len) orelse return .invalid_argument;
    const description = Plugins.input(info.description, max_description_len) orelse return .invalid_argument;
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(description)) return .invalid_argument;
    if (@backingInt(info.permission) > @backingInt(abi.CommandPermission.owner)) return .invalid_argument;
    var item: Plugins.PendingCommand = .{ .name = undefined, .len = text.len, .command = .{
        .callback = info.callback orelse return .invalid_argument,
        .user = info.user,
        .loaded = loaded,
        .permission = info.permission,
        .description_len = @intCast(description.len),
    } };
    @memcpy(item.command.description_buffer[0..description.len], description);
    for (text, item.name[0..text.len]) |char, *out| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') return .invalid_argument;
        out.* = std.ascii.toLower(char);
    }
    const lower = item.name[0..text.len];
    if (owner.commands.contains(lower)) return .invalid_argument;
    for (owner.pending_commands.items) |*other| if (std.mem.eql(u8, other.name[0..other.len], lower)) return .invalid_argument;
    owner.pending_commands.append(owner.gpa, item) catch return .failed;
    if (info.permission != .any and owner.options.operators.len == 0)
        log.warn("{s}'s /{s} is for operators, and [commands] operators lists none, so nobody can run it", .{ loaded.label(), lower });
    return .ok;
}

fn hostSpawnTask(context: *anyopaque, player: abi.Player, run: ?abi.TaskFn, done: ?abi.TaskDoneFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    if (!Work.hosted) return .wrong_thread;
    if (!loaded.ready.load(.acquire) or owner.stopping.load(.acquire) or !loaded.plugin.capabilities.tasks) return .unsupported;
    const pool = owner.pool orelse return .unsupported;
    const run_fn = run orelse return .invalid_argument;
    const done_fn = done orelse return .invalid_argument;
    if (!Work.reserve(&owner.outstanding, owner.options.max_tasks)) return .busy;
    if (!Work.reserve(&loaded.outstanding, owner.options.max_tasks_per_plugin)) {
        Work.release(&owner.outstanding);
        return .busy;
    }
    const task = owner.gpa.create(Work.Task) catch {
        Work.release(&loaded.outstanding);
        Work.release(&owner.outstanding);
        return .failed;
    };
    task.* = .{
        .run = run_fn,
        .outstanding = &loaded.outstanding,
        .then = .{ .done = done_fn, .user = user, .player = player, .name = loaded.label(), .metrics = loaded.metrics },
    };
    if (pool.submit(task)) return .ok;
    Work.release(&loaded.outstanding);
    Work.release(&owner.outstanding);
    owner.gpa.destroy(task);
    return .busy;
}

fn hostSendMessage(context: *anyopaque, player: abi.Player, text: abi.Str) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    if (!loaded.ready.load(.acquire)) return .unsupported;
    if (!owner.options.packets or owner.stopping.load(.acquire)) return .unsupported;
    const bytes = Plugins.input(text, Work.max_message_bytes) orelse return .invalid_argument;
    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return .invalid_argument;
    const route = owner.handles.route(player) orelse return .stale_handle;
    if (route.worker >= owner.queues.len) return .invalid_argument;
    if (!reserveMessage(loaded)) return .busy;
    const message = owner.gpa.create(Work.Message) catch {
        owner.releaseMessage(&loaded.quota);
        return .failed;
    };
    message.* = .{ .quota = &loaded.quota, .player = player, .len = bytes.len, .text = undefined };
    @memcpy(message.text[0..bytes.len], bytes);
    if (owner.queues[route.worker].post(.{ .message = message })) return .ok;
    owner.gpa.destroy(message);
    owner.releaseMessage(&loaded.quota);
    return .unsupported;
}

fn hostPost(context: *anyopaque, player: abi.Player, callback: ?abi.TaskDoneFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    const done = callback orelse return .invalid_argument;
    if (!loaded.ready.load(.acquire) or owner.stopping.load(.acquire)) return .unsupported;
    const route = owner.handles.route(player) orelse return .stale_handle;
    if (route.worker >= owner.queues.len) return .invalid_argument;
    if (!reserveMessage(loaded)) return .busy;
    const post = owner.gpa.create(Work.Post) catch {
        owner.releaseMessage(&loaded.quota);
        return .failed;
    };
    post.* = .{ .quota = &loaded.quota, .then = .{ .done = done, .user = user, .player = player, .name = loaded.label(), .metrics = loaded.metrics } };
    if (owner.queues[route.worker].post(.{ .post = post })) return .ok;
    owner.gpa.destroy(post);
    owner.releaseMessage(&loaded.quota);
    return .unsupported;
}

fn hostSendPacket(context: *anyopaque, player: abi.Player, target: abi.PacketTarget, bytes: abi.Str, callback: ?abi.TaskDoneFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    if (!owner.options.packets or !loaded.ready.load(.acquire)) return .unsupported;
    if (!loaded.plugin.capabilities.packets) return .unsupported;
    if (owner.stopping.load(.acquire)) return .canceled;
    if (bytes.ptr == null or bytes.len == 0 or bytes.len > injection.max_packet_bytes) return .invalid_argument;
    const status = injection.validate(target, bytes.slice());
    if (status != .ok) return status;
    const route = owner.handles.route(player) orelse return .stale_handle;
    if (route.worker >= owner.queues.len) return .invalid_argument;
    const length: u32 = @intCast(bytes.len);
    if (!reserveInjection(loaded, length)) return .busy;
    const then: ?Work.Done = if (callback) |done| .{ .done = done, .user = user, .player = player, .name = loaded.label(), .metrics = loaded.metrics } else null;
    const packet = Work.Injection.create(owner.gpa, &loaded.quota, player, target, route.epoch, bytes.slice(), then) catch {
        owner.releaseInjection(&loaded.quota, length);
        return .failed;
    };
    if (owner.queues[route.worker].post(.{ .packet = packet })) return .ok;
    packet.destroy(owner.gpa);
    owner.releaseInjection(&loaded.quota, length);
    return .canceled;
}

fn hostWorkerCount(context: *anyopaque) callconv(.c) u32 {
    return from(context).owner.options.workers;
}

fn hostBackendCount(context: *anyopaque) callconv(.c) u32 {
    return @intCast(from(context).owner.backends.len);
}

fn hostBackendName(context: *anyopaque, backend: u32, name: ?*abi.Str) callconv(.c) abi.Status {
    const backends = from(context).owner.backends;
    if (backend >= backends.len) return .invalid_argument;
    (name orelse return .invalid_argument).* = .of(backends[backend].name());
    return .ok;
}

fn hostBackendHealth(context: *anyopaque, player: abi.Player, backend: u32, out: ?*abi.BackendHealth) callconv(.c) abi.Status {
    const result = out orelse return .invalid_argument;
    const loaded = from(context);
    if (backend >= loaded.owner.backends.len) return .invalid_argument;
    return gameplayQuery(loaded, .events, player, .{ .backend_health = .{ .backend = backend, .out = result } });
}

fn hostPlayerName(context: *anyopaque, player: abi.Player, out: ?[*]u8, capacity: usize, len: ?*usize) callconv(.c) abi.Status {
    const full_len = len orelse return .invalid_argument;
    const buffer: []u8 = if (capacity == 0) &.{} else (out orelse return .invalid_argument)[0..capacity];
    full_len.* = from(context).owner.handles.copyName(player, buffer) orelse return .stale_handle;
    return .ok;
}

fn hostTransfer(context: *anyopaque, player: abi.Player, backend: u32) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    if (!Work.hosted) return .wrong_thread;
    if (!loaded.ready.load(.acquire)) return .unsupported;
    if (owner.stopping.load(.acquire)) return .canceled;
    if (backend >= owner.backends.len) return .invalid_argument;
    const route = owner.handles.route(player) orelse return .stale_handle;
    return route.transfer(route.context, route.link, backend);
}

fn hostPlayerInfo(context: *anyopaque, player: abi.Player, out: ?*abi.PlayerInfo, capacity: usize) callconv(.c) abi.Status {
    const result = out orelse return .invalid_argument;
    if (capacity < @sizeOf(abi.PlayerInfo)) return .invalid_argument;
    return if (from(context).owner.handles.copyInfo(player, result)) .ok else .stale_handle;
}

fn hostNetworkStats(context: *anyopaque, player: abi.Player, target: abi.PacketTarget, out: ?*abi.NetworkStats, capacity: usize) callconv(.c) abi.Status {
    const owner = from(context).owner;
    const result = out orelse return .invalid_argument;
    if (capacity < @sizeOf(abi.NetworkStats) or @backingInt(target) > 1) return .invalid_argument;
    const route = owner.handles.route(player) orelse return .stale_handle;
    if (Work.context != @as(*const anyopaque, owner) or Work.worker != route.worker) return .wrong_thread;
    const network = route.network orelse return .unsupported;
    return network(route.context, route.link, target, result);
}

fn hostPlayerGameplay(context: *anyopaque, player: abi.Player, out: ?*abi.Gameplay, capacity: usize) callconv(.c) abi.Status {
    const result = out orelse return .invalid_argument;
    if (capacity < @sizeOf(abi.Gameplay)) return .invalid_argument;
    return gameplayQuery(from(context), .gameplay, player, .{ .player = result });
}

fn hostFindEntity(context: *anyopaque, player: abi.Player, runtime_id: u64, out: ?*abi.Entity, capacity: usize) callconv(.c) abi.Status {
    const result = out orelse return .invalid_argument;
    if (capacity < @sizeOf(abi.Entity)) return .invalid_argument;
    return gameplayQuery(from(context), .entities, player, .{ .entity = .{ .runtime_id = runtime_id, .out = result } });
}

fn hostListEntities(context: *anyopaque, player: abi.Player, out: ?[*]abi.Entity, count: usize, total: ?*usize, whole: ?*u32) callconv(.c) abi.Status {
    const tracked = total orelse return .invalid_argument;
    const entities: []abi.Entity = if (count == 0) &.{} else (out orelse return .invalid_argument)[0..count];
    return gameplayQuery(from(context), .entities, player, .{ .entities = .{ .out = entities, .total = tracked, .complete = whole } });
}

fn gameplayQuery(loaded: *Loaded, comptime capability: std.meta.FieldEnum(abi.Capabilities), player: abi.Player, query: Handles.Query) abi.Status {
    if (!@field(loaded.plugin.capabilities, @tagName(capability))) return .unsupported;
    const owner = loaded.owner;
    const route = owner.handles.route(player) orelse return .stale_handle;
    if (Work.context != @as(*const anyopaque, owner) or Work.worker != route.worker) return .wrong_thread;
    const gameplay = route.gameplay orelse return .unsupported;
    return gameplay(route.context, route.link, query);
}

fn hostResumeLogin(context: *anyopaque, player: abi.Player, done: ?abi.TaskDoneFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    if (loaded.owner.admission != loaded) return .unsupported;
    return queueAction(from(context), player, .transfer, abi.no_backend, "", done, user);
}

fn hostLoginHints(context: *anyopaque, player: abi.Player, out: ?*abi.LoginHints, capacity: usize) callconv(.c) abi.Status {
    const result = out orelse return .invalid_argument;
    if (capacity < @sizeOf(abi.LoginHints)) return .invalid_argument;
    return gameplayQuery(from(context), .events, player, .{ .login_hints = result });
}

fn hostClientData(context: *anyopaque, player: abi.Player, out: ?*abi.Str) callconv(.c) abi.Status {
    return gameplayQuery(from(context), .packets, player, .{ .client_data = out orelse return .invalid_argument });
}

fn hostSetClientData(context: *anyopaque, player: abi.Player, json: abi.Str) callconv(.c) abi.Status {
    const bytes = Plugins.input(json, 1024 * 1024) orelse return .invalid_argument;
    return gameplayQuery(from(context), .packets, player, .{ .set_client_data = bytes });
}

fn hostDisconnect(context: *anyopaque, player: abi.Player, reason: abi.Str, done: ?abi.TaskDoneFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const bytes = Plugins.input(reason, Work.max_message_bytes) orelse return .invalid_argument;
    if (!std.unicode.utf8ValidateSlice(bytes)) return .invalid_argument;
    return queueAction(from(context), player, .disconnect, abi.no_backend, bytes, done, user);
}

fn hostRequestTransfer(context: *anyopaque, player: abi.Player, backend: u32, done: ?abi.TaskDoneFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    if (backend >= loaded.owner.backends.len) return .invalid_argument;
    return queueAction(loaded, player, .transfer, backend, "", done, user);
}

fn queueAction(loaded: *Loaded, player: abi.Player, kind: @FieldType(Work.Action, "kind"), backend: u32, reason: []const u8, callback: ?abi.TaskDoneFn, user: ?*anyopaque) abi.Status {
    const owner = loaded.owner;
    if (!loaded.ready.load(.acquire)) return .unsupported;
    if (owner.stopping.load(.acquire)) return .canceled;
    const route = owner.handles.route(player) orelse return .stale_handle;
    if (route.worker >= owner.queues.len) return .invalid_argument;
    if (!reserveMessage(loaded)) return .busy;
    const action = owner.gpa.create(Work.Action) catch {
        owner.releaseMessage(&loaded.quota);
        return .failed;
    };
    action.* = .{
        .quota = &loaded.quota,
        .player = player,
        .kind = kind,
        .backend = backend,
        .reason_len = reason.len,
        .then = if (callback) |done| .{ .done = done, .user = user, .player = player, .name = loaded.label(), .metrics = loaded.metrics } else null,
    };
    @memcpy(action.reason[0..reason.len], reason);
    if (owner.queues[route.worker].post(.{ .action = action })) return .ok;
    owner.gpa.destroy(action);
    owner.releaseMessage(&loaded.quota);
    return .canceled;
}
