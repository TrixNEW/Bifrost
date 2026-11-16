const std = @import("std");

pub fn ns(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

pub fn ms(io: std.Io) u64 {
    return ns(io) / std.time.ns_per_ms;
}
