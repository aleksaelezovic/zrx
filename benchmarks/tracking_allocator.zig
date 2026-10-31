//! Benchmark-local raw allocator accounting. The Io backend must use a separate
//! unwrapped allocator. All backing calls and statistics are serialized together.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Self = @This();

pub const Stats = struct {
    alloc_attempts: usize = 0,
    alloc_successes: usize = 0,
    alloc_requested_bytes: usize = 0,
    fresh_bytes: usize = 0,
    resize_attempts: usize = 0,
    resize_successes: usize = 0,
    remap_attempts: usize = 0,
    remap_successes: usize = 0,
    free_calls: usize = 0,
    growth_bytes: usize = 0,
    released_bytes: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    live_allocations: usize = 0,
    peak_live_allocations: usize = 0,

    pub fn clean(self: Stats) bool {
        return self.live_bytes == 0 and self.live_allocations == 0;
    }
};

backing: Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,
stats: Stats = .{},

pub fn init(backing: Allocator, io: std.Io) Self {
    return .{ .backing = backing, .io = io };
}

pub fn allocator(self: *Self) Allocator {
    return .{ .ptr = self, .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    } };
}

pub fn snapshot(self: *Self) Stats {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.stats;
}

/// Call only after every allocator user has stopped/joined. Outstanding storage
/// is an error rather than silently starting a new accounting epoch.
pub fn reset(self: *Self) error{OutstandingAllocations}!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (!self.stats.clean()) return error.OutstandingAllocations;
    self.stats = .{};
}

fn add(counter: *usize, amount: usize) void {
    counter.* = std.math.add(usize, counter.*, amount) catch @panic("measurement counter overflow");
}
fn subtract(counter: *usize, amount: usize) void {
    if (counter.* < amount) @panic("measurement allocation accounting underflow");
    counter.* -= amount;
}
fn changed(self: *Self, old_len: usize, new_len: usize) void {
    if (new_len >= old_len) {
        add(&self.stats.growth_bytes, new_len - old_len);
        add(&self.stats.live_bytes, new_len - old_len);
    } else {
        add(&self.stats.released_bytes, old_len - new_len);
        subtract(&self.stats.live_bytes, old_len - new_len);
    }
    self.stats.peak_live_bytes = @max(self.stats.peak_live_bytes, self.stats.live_bytes);
}
fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    add(&self.stats.alloc_attempts, 1);
    add(&self.stats.alloc_requested_bytes, len);
    const memory = self.backing.rawAlloc(len, alignment, return_address) orelse return null;
    add(&self.stats.alloc_successes, 1);
    add(&self.stats.fresh_bytes, len);
    add(&self.stats.live_bytes, len);
    add(&self.stats.live_allocations, 1);
    self.stats.peak_live_bytes = @max(self.stats.peak_live_bytes, self.stats.live_bytes);
    self.stats.peak_live_allocations = @max(self.stats.peak_live_allocations, self.stats.live_allocations);
    return memory;
}
fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, return_address: usize) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    add(&self.stats.resize_attempts, 1);
    if (!self.backing.rawResize(memory, alignment, new_len, return_address)) return false;
    add(&self.stats.resize_successes, 1);
    self.changed(memory.len, new_len);
    return true;
}
fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, return_address: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    add(&self.stats.remap_attempts, 1);
    const result = self.backing.rawRemap(memory, alignment, new_len, return_address) orelse return null;
    add(&self.stats.remap_successes, 1);
    // A remap is one logical live allocation, even if its address changes.
    self.changed(memory.len, new_len);
    return result;
}
fn free(context: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.backing.rawFree(memory, alignment, return_address);
    add(&self.stats.free_calls, 1);
    add(&self.stats.released_bytes, memory.len);
    subtract(&self.stats.live_bytes, memory.len);
    subtract(&self.stats.live_allocations, 1);
}
