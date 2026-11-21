const std = @import("std");
const NetherNet = @import("../net/NetherNet.zig");
const Notify = @import("../net/Notify.zig");
const Backend = @import("Backend.zig");

const Dial = @This();

pub const Result = anyerror!*NetherNet.Connection;

done: std.atomic.Value(bool) = .init(false),
result: Result = undefined,

pub fn run(self: *Dial, transport: *const NetherNet, backend: *const Backend, notify: Notify) void {
    self.result = transport.dial(backend);
    self.done.store(true, .release);
    notify.send();
}

pub fn finished(self: *const Dial) ?Result {
    if (!self.done.load(.acquire)) return null;
    return self.result;
}

pub fn cancel(self: *Dial, task: *std.Io.Future(void), io: std.Io) void {
    task.cancel(io);
    if (self.finished()) |result| {
        if (result) |connection| connection.destroy() else |_| {}
    }
}
