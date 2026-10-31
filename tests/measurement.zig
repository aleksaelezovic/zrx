const std = @import("std");
const Meter = @import("meter");
const Spans = @import("spans");
const workloads = @import("workloads");
const allocator = std.testing.allocator;
const io = std.testing.io;

comptime {
    _ = @import("phase_observation.zig");
}

/// Deterministic allocator outcomes, including a real pointer move between
/// fixed buffers. All pointer/size/alignment/address forwarding is checked.
const Scripted = struct {
    first: [128]u8 align(16) = undefined,
    second: [128]u8 align(16) = undefined,
    current: ?[*]u8 = null,
    len: usize = 0,
    allow_alloc: bool = false,
    allow_resize: bool = false,
    allow_remap: bool = false,
    move: bool = true,
    last_alignment: std.mem.Alignment = .of(u8),
    last_address: usize = 0,

    fn get(self: *Scripted) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn record(self: *Scripted, alignment: std.mem.Alignment, address: usize) void {
        self.last_alignment = alignment;
        self.last_address = address;
    }
    fn check(self: *Scripted, memory: []u8) void {
        if (self.current != memory.ptr or self.len != memory.len) @panic("wrong delegated allocation");
    }
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Scripted = @ptrCast(@alignCast(raw));
        self.record(alignment, address);
        if (!self.allow_alloc or len > self.first.len) return null;
        if (self.current != null) @panic("script supports one live allocation");
        self.current = &self.first;
        self.len = len;
        return &self.first;
    }
    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
        const self: *Scripted = @ptrCast(@alignCast(raw));
        self.record(alignment, address);
        self.check(memory);
        if (!self.allow_resize or len > self.first.len) return false;
        self.len = len;
        return true;
    }
    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
        const self: *Scripted = @ptrCast(@alignCast(raw));
        self.record(alignment, address);
        self.check(memory);
        if (!self.allow_remap or len > self.second.len) return null;
        if (self.move) {
            @memcpy(self.second[0..@min(memory.len, len)], memory[0..@min(memory.len, len)]);
            self.current = &self.second;
        }
        self.len = len;
        return self.current.?;
    }
    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Scripted = @ptrCast(@alignCast(raw));
        self.record(alignment, address);
        self.check(memory);
        self.current = null;
        self.len = 0;
    }
};

test "raw allocation accounting handles failures growth shrink moving remap and balance" {
    var backing: Scripted = .{};
    var meter: Meter = .init(backing.get(), io);
    const gpa = meter.allocator();
    const alignment: std.mem.Alignment = .fromByteUnits(16);
    try std.testing.expect(gpa.rawAlloc(8, alignment, 11) == null);
    try std.testing.expectEqual(@as(usize, 0), meter.snapshot().live_bytes);
    backing.allow_alloc = true;
    var memory: []u8 = (gpa.rawAlloc(16, alignment, 12) orelse return error.OutOfMemory)[0..16];
    @memset(memory, 0x5a);
    try std.testing.expectEqual(alignment, backing.last_alignment);
    try std.testing.expectEqual(@as(usize, 12), backing.last_address);
    try std.testing.expectError(error.OutstandingAllocations, meter.reset());
    try std.testing.expect(!gpa.rawResize(memory, alignment, 32, 13));
    try std.testing.expectEqual(@as(usize, 16), meter.snapshot().live_bytes);
    backing.allow_resize = true;
    try std.testing.expect(gpa.rawResize(memory, alignment, 24, 14));
    memory = memory.ptr[0..24];
    try std.testing.expect(gpa.rawResize(memory, alignment, 12, 15));
    memory = memory.ptr[0..12];
    try std.testing.expect(gpa.rawRemap(memory, alignment, 40, 16) == null);
    try std.testing.expectEqual(@as(usize, 12), meter.snapshot().live_bytes);
    backing.allow_remap = true;
    const moved = gpa.rawRemap(memory, alignment, 40, 17) orelse return error.RemapFailed;
    try std.testing.expect(moved != memory.ptr);
    memory = moved[0..40];
    for (memory[0..12]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    backing.move = false;
    memory = (gpa.rawRemap(memory, alignment, 10, 18) orelse return error.RemapFailed)[0..10];
    try std.testing.expect(gpa.rawResize(memory, alignment, 10, 19));
    gpa.rawFree(memory, alignment, 20);
    try std.testing.expectEqual(alignment, backing.last_alignment);
    try std.testing.expectEqual(@as(usize, 20), backing.last_address);
    const stats = meter.snapshot();
    try std.testing.expect(stats.clean());
    try std.testing.expectEqual(@as(usize, 2), stats.alloc_attempts);
    try std.testing.expectEqual(@as(usize, 1), stats.alloc_successes);
    try std.testing.expectEqual(@as(usize, 24), stats.alloc_requested_bytes);
    try std.testing.expectEqual(@as(usize, 16), stats.fresh_bytes);
    try std.testing.expectEqual(@as(usize, 4), stats.resize_attempts);
    try std.testing.expectEqual(@as(usize, 3), stats.resize_successes);
    try std.testing.expectEqual(@as(usize, 3), stats.remap_attempts);
    try std.testing.expectEqual(@as(usize, 2), stats.remap_successes);
    try std.testing.expectEqual(@as(usize, 36), stats.growth_bytes);
    try std.testing.expectEqual(@as(usize, 52), stats.released_bytes);
    try std.testing.expectEqual(@as(usize, 40), stats.peak_live_bytes);
    try std.testing.expectEqual(@as(usize, 1), stats.peak_live_allocations);
    try std.testing.expectEqual(@as(usize, 1), stats.free_calls);
    try meter.reset();
    try std.testing.expectEqualDeep(Meter.Stats{}, meter.snapshot());
}

test "concurrent users serialize a non-thread-safe backing allocator and counters" {
    var backing: std.testing.FailingAllocator = .init(allocator, .{});
    var meter: Meter = .init(backing.allocator(), io);
    const Helpers = struct {
        fn work(observed: *Meter) anyerror!void {
            const gpa = observed.allocator();
            for (0..128) |_| {
                const first = try gpa.alloc(u8, 32);
                defer gpa.free(first);
                const second = try gpa.alloc(u8, 64);
                defer gpa.free(second);
                @memset(first, 1);
                @memset(second, 2);
                const snapshot = observed.snapshot();
                try std.testing.expectEqual(snapshot.fresh_bytes + snapshot.growth_bytes - snapshot.released_bytes, snapshot.live_bytes);
                try std.testing.expectEqual(snapshot.alloc_successes - snapshot.free_calls, snapshot.live_allocations);
                try std.testing.expect(snapshot.peak_live_bytes >= snapshot.live_bytes);
            }
        }
    };
    var tasks: [8]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer for (tasks[0..started]) |*task| task.cancel(io) catch {};
    for (&tasks) |*task| {
        task.* = try io.concurrent(Helpers.work, .{&meter});
        started += 1;
    }
    for (&tasks) |*task| try task.await(io);
    const stats = meter.snapshot();
    try std.testing.expect(stats.clean());
    try std.testing.expectEqual(@as(usize, 2048), stats.alloc_successes);
    try std.testing.expectEqual(stats.alloc_successes, stats.alloc_attempts);
    try std.testing.expectEqual(stats.alloc_successes, stats.free_calls);
    try std.testing.expectEqual(@as(usize, 98304), stats.fresh_bytes);
    try std.testing.expectEqual(stats.fresh_bytes, stats.released_bytes);
    try std.testing.expect(stats.peak_live_bytes >= 96 and stats.peak_live_bytes <= 8 * 96);
    try std.testing.expectEqual(stats.alloc_successes, backing.allocations);
    try std.testing.expectEqual(stats.free_calls, backing.deallocations);
    try std.testing.expectEqual(stats.fresh_bytes, backing.allocated_bytes);
}

test "real graph allocation pass preserves results and frees all tracked storage" {
    inline for (.{ workloads.Shape.linear, workloads.Shape.fanout }) |shape| {
        const expected = try workloads.execute(shape, .direct, allocator, io, 32, 4);
        inline for (.{ workloads.Variant.direct, workloads.Variant.graph, workloads.Variant.current }) |variant| {
            var meter: Meter = .init(allocator, io);
            const result = try workloads.execute(shape, variant, meter.allocator(), io, 32, 4);
            try workloads.verify(shape, 32, expected, result);
            const stats = meter.snapshot();
            try std.testing.expect(stats.clean());
            try std.testing.expectEqual(stats.alloc_successes, stats.free_calls);
            try std.testing.expectEqual(stats.fresh_bytes + stats.growth_bytes, stats.released_bytes);
            if (variant == .direct) try std.testing.expectEqual(@as(usize, 0), stats.alloc_attempts);
        }
    }
}

fn failedRun(gpa: std.mem.Allocator, comptime variant: workloads.Variant) !void {
    var meter: Meter = .init(gpa, io);
    const result = workloads.execute(.fanout, variant, meter.allocator(), io, 7, 2);
    const stats = meter.snapshot();
    try std.testing.expect(stats.clean());
    try std.testing.expectEqual(stats.alloc_successes, stats.free_calls);
    try std.testing.expectEqual(stats.fresh_bytes + stats.growth_bytes, stats.released_bytes);
    _ = try result;
}
fn failedLegacy(gpa: std.mem.Allocator) !void {
    try failedRun(gpa, .graph);
}
fn failedCurrent(gpa: std.mem.Allocator) !void {
    try failedRun(gpa, .current);
}
test "failed graph preparation leaves balanced accounting at every allocation failure" {
    try std.testing.checkAllAllocationFailures(allocator, failedLegacy, .{});
    try std.testing.checkAllAllocationFailures(allocator, failedCurrent, .{});
}

test "callback checkpoint spans partition elapsed time without timing thresholds" {
    var trace: Spans = .init(io);
    trace.sourceEnter();
    trace.sinkEnter();
    trace.sinkExit();
    trace.sourceExit();
    const sample = try trace.finish();
    try std.testing.expectEqual(@as(usize, 1), sample.sink_entries);
    try std.testing.expectEqual(@as(usize, 1), sample.sink_exits);
    try std.testing.expectEqual(sample.elapsed_ns, sample.first_source_entry_ns + sample.callbackWindow() + sample.returnTail());
    try std.testing.expect(sample.first_sink_entry_ns.? >= sample.first_source_entry_ns);
    var empty: Spans = .init(io);
    empty.sourceEnter();
    empty.sourceExit();
    const empty_sample = try empty.finish();
    try std.testing.expect(empty_sample.first_sink_entry_ns == null and empty_sample.last_sink_exit_ns == null);
}

test "concurrent callback checkpoints retain all counts and final maximum" {
    const Helpers = struct {
        fn work(trace: *Spans) void {
            for (0..128) |_| {
                trace.sinkEnter();
                trace.sinkExit();
            }
        }
    };
    var trace: Spans = .init(io);
    trace.sourceEnter();
    var tasks: [8]std.Io.Future(void) = undefined;
    var started: usize = 0;
    defer for (tasks[0..started]) |*task| task.cancel(io);
    for (&tasks) |*task| {
        task.* = try io.concurrent(Helpers.work, .{&trace});
        started += 1;
    }
    for (&tasks) |*task| task.await(io);
    trace.sourceExit();
    const sample = try trace.finish();
    try std.testing.expectEqual(@as(usize, 1024), sample.sink_entries);
    try std.testing.expectEqual(sample.sink_entries, sample.sink_exits);
    try std.testing.expectEqual(sample.producer_exit_ns, sample.last_observed_exit_ns);
}
