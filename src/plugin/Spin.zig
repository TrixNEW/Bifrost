const std = @import("std");

/// For sections a few instructions long that any thread may enter, where parking a waiter would cost more than the wait.
const Spin = @This();

held: std.atomic.Value(bool) = .init(false),

pub fn lock(self: *Spin) void {
    while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

pub fn unlock(self: *Spin) void {
    self.held.store(false, .release);
}
