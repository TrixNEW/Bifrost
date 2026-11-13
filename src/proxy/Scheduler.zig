const std = @import("std");
const Link = @import("Link.zig");
const Notify = @import("../net/Notify.zig");

const Scheduler = @This();

io: std.Io,
wake: std.Io.Event = .unset,
ready: std.atomic.Value(?*Link) = .init(null),

pub fn schedule(self: *Scheduler, link: *Link) void {
    _ = self.push(link);
}

// False when the link was already queued, and whoever queued it has a service still to come.
// seq_cst pairs with the worker clearing `queued` before it looks for work, so one of the two sees the other.
fn push(self: *Scheduler, link: *Link) bool {
    if (link.queued.load(.seq_cst) or link.queued.swap(true, .seq_cst)) return false;
    var head = self.ready.load(.monotonic);
    while (true) {
        link.next_ready = head;
        head = self.ready.cmpxchgWeak(head, link, .release, .monotonic) orelse return true;
    }
}

pub fn takeReady(self: *Scheduler) ?*Link {
    return self.ready.swap(null, .acquire);
}

pub fn hasReady(self: *const Scheduler) bool {
    return self.ready.load(.monotonic) != null;
}

pub fn wakeNotify(self: *Scheduler) Notify {
    return .{ .context = self, .call = wakeOnly };
}

pub fn linkNotify(link: *Link) Notify {
    return .{ .context = link, .call = notifyLink };
}

fn wakeOnly(context: *anyopaque) void {
    const self: *Scheduler = @ptrCast(@alignCast(context));
    self.wake.set(self.io);
}

// Whoever queues the link wakes the worker, so a burst costs one wake
fn notifyLink(context: *anyopaque) void {
    const link: *Link = @ptrCast(@alignCast(context));
    const self = link.env.scheduler;
    if (self.push(link)) self.wake.set(self.io);
}
