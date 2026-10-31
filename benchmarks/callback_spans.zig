//! Coarse benchmark callback checkpoints, NOT exact executor phases or CPU time.
//! Clock/lock instrumentation perturbs scheduling; never mix with headline timing.
//! A sink pair bounds its first callback entry through its final callback exit;
//! sink marker counts are not item/callback invocation counts.
const std = @import("std");
const Self = @This();
pub const Sample = struct {
    elapsed_ns: u64,
    first_source_entry_ns: u64,
    producer_exit_ns: u64,
    first_sink_entry_ns: ?u64,
    last_sink_exit_ns: ?u64,
    last_observed_exit_ns: u64,
    sink_entries: usize,
    sink_exits: usize,

    pub fn callbackWindow(self: Sample) u64 {
        return self.last_observed_exit_ns - self.first_source_entry_ns;
    }
    pub fn returnTail(self: Sample) u64 {
        return self.elapsed_ns - self.last_observed_exit_ns;
    }
};
io: std.Io,
start: std.Io.Timestamp,
mutex: std.Io.Mutex = .init,
source_entries: usize = 0,
source_exits: usize = 0,
first_source: ?u64 = null,
producer_exit: ?u64 = null,
first_sink: ?u64 = null,
last_sink: ?u64 = null,
last_exit: ?u64 = null,
sink_entries: usize = 0,
sink_exits: usize = 0,

pub fn init(io: std.Io) Self {
    return .{ .io = io, .start = std.Io.Clock.awake.now(io) };
}
fn now(self: *const Self) u64 {
    const ns = self.start.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds();
    return std.math.cast(u64, ns) orelse @panic("callback clock moved backwards or overflowed");
}
pub fn sourceEnter(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.source_entries += 1;
    self.first_source = self.now();
}
pub fn sourceExit(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.source_exits += 1;
    const stamp = self.now();
    self.producer_exit = stamp;
    self.last_exit = @max(self.last_exit orelse 0, stamp);
}
pub fn sinkEnter(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.sink_entries += 1;
    if (self.first_sink == null) self.first_sink = self.now();
}
pub fn sinkExit(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.sink_exits += 1;
    const stamp = self.now();
    self.last_sink = stamp;
    self.last_exit = @max(self.last_exit orelse 0, stamp);
}

/// Call after run returned and all callback users joined. Empty inputs have no
/// sink checkpoints. The producer can exit before OR after the final sink.
pub fn finish(self: *Self) error{InvalidCallbackTrace}!Sample {
    const elapsed = self.now();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.source_entries != 1 or self.source_exits != 1 or self.sink_entries != self.sink_exits)
        return error.InvalidCallbackTrace;
    const first = self.first_source orelse return error.InvalidCallbackTrace;
    const producer = self.producer_exit orelse return error.InvalidCallbackTrace;
    const last = self.last_exit orelse return error.InvalidCallbackTrace;
    if (first > producer or last > elapsed) return error.InvalidCallbackTrace;
    if (self.first_sink) |sink| {
        if (sink < first or self.last_sink.? < sink) return error.InvalidCallbackTrace;
    }
    return .{
        .elapsed_ns = elapsed,
        .first_source_entry_ns = first,
        .producer_exit_ns = producer,
        .first_sink_entry_ns = self.first_sink,
        .last_sink_exit_ns = self.last_sink,
        .last_observed_exit_ns = last,
        .sink_entries = self.sink_entries,
        .sink_exits = self.sink_exits,
    };
}
