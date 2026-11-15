const std = @import("std");
const zio = @import("zio");
const bifrost = @import("bifrost");

const log = bifrost.log.scoped(.server);
const config_log = bifrost.log.scoped(.config);
const net_log = bifrost.log.scoped(.network);

pub const std_options_debug_io = zio.debug_io;
// Plugin calls keep their context per thread, so a task must never move to another executor mid-call
pub const zio_options: zio.Options = .{ .scheduling = .pinned };
pub const std_options: std.Options = .{
    .logFn = bifrost.log.logFn,
    // Everything reaches logFn, which filters by the [logging] levels at runtime
    .log_level = .debug,
    .log_scope_levels = &.{.{ .scope = .zio, .level = .info }},
};

const config_path = "config/bifrost.toml";

pub fn main(init: std.process.Init) !void {
    const started = std.Io.Clock.awake.now(init.io);
    bifrost.tuneAllocator();
    log.info("Starting Bifrost {s}", .{bifrost.version});
    const config = loadConfig(init);
    const log_settings = config.logSettings();
    bifrost.log.configure(log_settings) catch |err| {
        var console_only = log_settings;
        console_only.file = null;
        bifrost.log.configure(console_only) catch unreachable;
        config_log.err("Can't open log file {s}: {t}; logging to the console only", .{ log_settings.file.?, err });
    };
    defer bifrost.log.deinit();
    // Prints straight to the console, so only a console at trace turns it on
    if (log_settings.level == .trace) bifrost.enableNativeTrace();

    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(config.workers) });
    defer rt.deinit();

    // Reloaded on the runtime's tasks, so they use its io
    var keys: ?bifrost.Keys = if (config.keysFile()) |keys_path| bifrost.Keys.load(init.gpa, rt.io(), keys_path) catch |err|
        fatal("can't load auth keys {s}: {t}", .{ keys_path, err }) else null;
    defer if (keys) |*set| set.deinit();
    const auth: bifrost.Auth = switch (config.auth) {
        .off => .off,
        .verify => .{ .verify = &keys.? },
    };

    const proxy_key = switch (config.session_mode) {
        .passthrough => null,
        .managed => bifrost.loadProxyKey(init.io, config.proxyKeyFile().?) catch |err|
            fatal("can't load proxy key {s}: {t}", .{ config.proxyKeyFile().?, err }),
    };
    if (config.auth == .off) config_log.warn("Auth is off: logins aren't verified, and NetherNet has no Minecraft encryption, so a captured login can be replayed", .{});

    // Players confirm this key once, so it has to survive restarts
    const identity = bifrost.loadIdentity(init.io, init.gpa, config.identityFile()) catch |err|
        fatal("can't load NetherNet identity {s}: {t}", .{ config.identityFile(), err });
    for ([_]?[]const u8{ config.proxyKeyFile(), config.identityFile() }) |key_file| {
        const path = key_file orelse continue;
        if (bifrost.exposedKeyMode(init.io, path)) |mode|
            config_log.warn("{s} has mode {o:0>3}, so other accounts can read this private key; run chmod 600 {s}", .{ path, mode, path });
    }
    if (config.auth == .verify)
        config_log.info("Backends must trust proxy key {s}", .{&bifrost.proxyKeyText(proxy_key orelse identity)})
    else
        config_log.debug("Backends see a throwaway proxy key while auth is off", .{});
    if (config.native_threads != 0) bifrost.setNativeThreads(config.native_threads) catch |err|
        fatal("can't use {d} NetherNet threads: {t}", .{ config.native_threads, err });

    var plugins: bifrost.Plugins = try .init(init.gpa, config.backends(), .{
        .workers = config.workers,
        .packets = config.session_mode == .managed,
        .slow_callback_ns = @as(u64, config.slow_plugin_callback_ms) * std.time.ns_per_ms,
        .task_threads = config.plugin_task_threads,
        .operators = config.operators(),
    });
    defer plugins.deinit();
    var disabled: [bifrost.Config.max_disabled_plugins][]const u8 = undefined;
    for (disabled[0..config.disabled_count], 0..) |*name, i| name.* = config.disabledPlugin(i);
    bifrost.Plugins.Package.discover(&plugins, init.io, config.pluginsDir(), disabled[0..config.disabled_count]) catch |err| {
        log.err("can't load plugins from {s}: {t}", .{ config.pluginsDir(), err });
        return error.PluginLoadFailed;
    };

    const workers = bifrost.Workers.create(init.gpa, rt.io(), config, .{
        .auth = auth,
        .proxy_key = proxy_key,
        // Without plugins there are no handles to keep, events to queue or packet tables to check
        .plugins = if (plugins.loaded.items.len != 0) &plugins else null,
        .identity = identity,
        .verify_signaling = true,
        .console = true,
    }) catch |err| {
        net_log.err("can't listen on {f}: {t}{s}", .{ config.bind, err, if (err == error.AddressInUse) " (is another server using the port?)" else "" });
        std.process.exit(1);
    };
    defer workers.destroy();
    defer plugins.unload();

    var signals = try rt.spawn(stopOnSignal, .{workers});
    defer signals.cancel();

    net_log.info("NetherNet listening on {f}", .{workers.localAddress()});
    log.info("Bifrost ready in {f} ({d} worker{s}, {d} backend{s})", .{
        bifrost.log.elapsed(sinceMs(init.io, started)),
        config.workers,
        plural(config.workers),
        config.backends().len,
        plural(config.backends().len),
    });
    try workers.run();
    const totals = workers.totals();
    log.info("Stopped after {f}, {d} connection{s} served", .{ bifrost.log.elapsed(sinceMs(init.io, started)), totals.sessions_accepted, plural(totals.sessions_accepted) });
}

fn loadConfig(init: std.process.Init) bifrost.Config {
    var diag: bifrost.Diagnostic = .{};
    const config = bifrost.loadConfig(init.gpa, init.io, config_path, &diag) catch |err| switch (err) {
        error.FileNotFound => {
            config_log.info("No {s}, using the built-in defaults", .{config_path});
            return bifrost.parseConfig(init.gpa, @embedFile("default_config"), &diag) catch |default_err|
                fatal("built-in config is invalid: {t}", .{default_err});
        },
        error.InvalidSyntax, error.InvalidConfig => fatal("{s} is invalid: {f}", .{ config_path, diag }),
        else => fatal("can't read {s}: {t}", .{ config_path, err }),
    };
    config_log.info("Loaded {s} ({d} backend{s}, {t} sessions, auth {t})", .{ config_path, config.backends().len, plural(config.backends().len), config.session_mode, config.auth });
    return config;
}

fn sinceMs(io: std.Io, started: std.Io.Timestamp) u64 {
    return @intCast(@max(0, started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds()));
}

fn plural(count: anytype) []const u8 {
    return if (count == 1) "" else "s";
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    config_log.err(format, args);
    std.process.exit(1);
}

fn stopOnSignal(workers: *bifrost.Workers) void {
    var interrupt = zio.Signal.init(.interrupt) catch |err| return log.warn("Signal handling unavailable, Ctrl+C won't stop cleanly: {t}", .{err});
    defer interrupt.deinit();
    var terminate = zio.Signal.init(.terminate) catch |err| return log.warn("Signal handling unavailable, SIGTERM won't stop cleanly: {t}", .{err});
    defer terminate.deinit();
    const signal = zio.select(.{ .interrupt = &interrupt, .terminate = &terminate }) catch return;
    log.info("Shutting down ({t})", .{signal});
    workers.stop();
}
