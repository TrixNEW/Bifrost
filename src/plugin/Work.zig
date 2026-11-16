const std = @import("std");
const abi = @import("abi.zig");
const Notify = @import("../net/Notify.zig");
const Packets = @import("Packets.zig");
const Spin = @import("Spin.zig");

pub const max_message_bytes = 1024;

// True while we're the ones calling into a plugin
pub threadlocal var hosted: bool = false;
pub threadlocal var worker: u32 = abi.no_worker;
pub threadlocal var context: ?*const anyopaque = null;

pub fn enter() bool {
    const outer = hosted;
    hosted = true;
    return outer;
}

/// A plugin callback running on `on` for `owner`. Calls nest, so leaving restores whatever was running before.
pub const Scope = struct {
    hosted: bool,
    worker: u32,
    context: ?*const anyopaque,

    pub fn enter(on: u32, owner: ?*const anyopaque) Scope {
        const outer: Scope = .{ .hosted = hosted, .worker = worker, .context = context };
        hosted = true;
        worker = on;
        context = owner;
        return outer;
    }

    pub fn leave(outer: Scope) void {
        hosted = outer.hosted;
        worker = outer.worker;
        context = outer.context;
    }
};

pub const Done = struct {
    done: abi.TaskDoneFn,
    user: ?*anyopaque,
    player: abi.Player,
    name: []const u8,
    metrics: []Packets.Metrics,
};

pub const Quota = struct {
    messages: std.atomic.Value(u32) = .init(0),
    injection_bytes: std.atomic.Value(u32) = .init(0),
};

pub const Post = struct {
    then: Done,
    quota: *Quota,
};

pub const Task = struct {
    run: abi.TaskFn,
    outstanding: *std.atomic.Value(u32),
    then: Done,
};

pub const Message = struct {
    quota: *Quota,
    player: abi.Player,
    len: usize,
    text: [max_message_bytes]u8,
};

pub const Item = union(enum) {
    task: *Task,
    message: *Message,
    post: *Post,
    packet: *Injection,
    action: *Action,
};

pub const Action = struct {
    quota: *Quota,
    player: abi.Player,
    kind: enum { disconnect, transfer },
    backend: u32 = abi.no_backend,
    reason_len: usize = 0,
    reason: [max_message_bytes]u8 = undefined,
    then: ?Done,
};

pub const Injection = struct {
    quota: *Quota,
    player: abi.Player,
    target: abi.PacketTarget,
    epoch: u64,
    len: usize,
    then: ?Done,

    pub fn create(gpa: std.mem.Allocator, quota: *Quota, player: abi.Player, target: abi.PacketTarget, epoch: u64, data: []const u8, then: ?Done) !*Injection {
        const allocation = try gpa.alignedAlloc(u8, .of(Injection), @sizeOf(Injection) + data.len);
        const self: *Injection = @ptrCast(allocation.ptr);
        self.* = .{ .quota = quota, .player = player, .target = target, .epoch = epoch, .len = data.len, .then = then };
        @memcpy(self.bytes(), data);
        return self;
    }

    pub fn bytes(self: *Injection) []u8 {
        return (@as([*]u8, @ptrCast(self)) + @sizeOf(Injection))[0..self.len];
    }

    pub fn destroy(self: *Injection, gpa: std.mem.Allocator) void {
        gpa.free(@as([*]align(@alignOf(Injection)) u8, @ptrCast(self))[0 .. @sizeOf(Injection) + self.len]);
    }
};

// Anyone can post, only the owning worker takes
pub const Queue = struct {
    lock: Spin = .{},
    items: std.ArrayList(Item) = .empty,
    taken: std.ArrayList(Item) = .empty,
    closed: bool = false,
    notify: ?Notify = null,

    pub fn init(gpa: std.mem.Allocator, capacity: usize) !Queue {
        var queue: Queue = .{};
        errdefer queue.deinit(gpa);
        try queue.items.ensureTotalCapacity(gpa, capacity);
        try queue.taken.ensureTotalCapacity(gpa, capacity);
        return queue;
    }

    pub fn deinit(self: *Queue, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
        self.taken.deinit(gpa);
    }

    // Callers bound the total, so this never grows
    pub fn post(self: *Queue, item: Item) bool {
        self.lock.lock();
        const open = !self.closed;
        if (open) self.items.appendAssumeCapacity(item);
        self.lock.unlock();
        if (open) if (self.notify) |notify| notify.send();
        return open;
    }

    pub fn close(self: *Queue) void {
        self.lock.lock();
        self.closed = true;
        self.lock.unlock();
    }

    pub fn take(self: *Queue) []const Item {
        self.taken.clearRetainingCapacity();
        self.lock.lock();
        std.mem.swap(std.ArrayList(Item), &self.items, &self.taken);
        self.lock.unlock();
        return self.taken.items;
    }
};

pub fn reserve(counter: *std.atomic.Value(u32), limit: u32) bool {
    return reserveBytes(counter, limit, 1);
}

pub fn reserveBytes(counter: *std.atomic.Value(u32), limit: u32, size: u32) bool {
    var current = counter.load(.monotonic);
    while (size <= limit and current <= limit - size) {
        current = counter.cmpxchgWeak(current, current + size, .acq_rel, .monotonic) orelse return true;
    }
    return false;
}

pub fn release(counter: *std.atomic.Value(u32)) void {
    _ = counter.fetchSub(1, .acq_rel);
}

test "a queue hands everything posted so far to its worker" {
    const gpa = std.testing.allocator;
    var queue: Queue = try .init(gpa, 4);
    defer queue.deinit(gpa);
    var message: Message = undefined;
    try std.testing.expect(queue.post(.{ .message = &message }));
    try std.testing.expect(queue.post(.{ .message = &message }));
    try std.testing.expectEqual(@as(usize, 2), queue.take().len);
    try std.testing.expect(queue.post(.{ .message = &message }));
    queue.close();
    try std.testing.expect(!queue.post(.{ .message = &message }));
    try std.testing.expectEqual(@as(usize, 1), queue.take().len);
    try std.testing.expectEqual(@as(usize, 0), queue.take().len);

    var counter: std.atomic.Value(u32) = .init(0);
    try std.testing.expect(reserve(&counter, 2));
    try std.testing.expect(reserve(&counter, 2));
    try std.testing.expect(!reserve(&counter, 2));
    release(&counter);
    try std.testing.expect(reserve(&counter, 2));
}
