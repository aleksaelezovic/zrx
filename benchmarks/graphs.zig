//! Opt-in complete-run timings, not an optimization or timing-threshold test.
//! Protocol, exclusions, and structural estimates: docs/measurements/elapsed.md.
const std = @import("std");
const builtin = @import("builtin");
const zrx = @import("api").legacy;
const current = @import("api").current;
const currentPipe = current.pipe;
const currentEach = current.each;
const currentFilter = current.filter;
const currentForEach = current.forEach;
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const forEachWith = zrx.forEachWith;
const api = @import("api");

pub const Shape = enum { linear, fanout };
pub const Variant = enum { direct, graph, current };
pub const Packet = struct { value: u64, evaluations: *usize };
pub const Producer = struct {
    items: usize,
    calls: usize = 0,
    produced: usize = 0,
    evaluations: usize = 0,
};
pub const Sink = struct {
    count: usize = 0,
    hash: u64 = 0,

    pub fn accept(self: *Sink, value: u64) void {
        self.count += 1;
        self.hash = (self.hash ^ value) *% 0x100000001b3;
    }
};
const LeftSink = struct { value: *Sink };
const RightSink = struct { value: *Sink };
fn acceptLeft(sink: LeftSink, value: u64) void {
    sink.value.accept(value);
}
fn acceptRight(sink: RightSink, value: u64) void {
    sink.value.accept(value);
}
pub const Result = struct {
    calls: usize,
    produced: usize,
    evaluations: usize,
    left: Sink,
    right: Sink,
};

pub fn produce(state: *Producer, output: *Emitter(Packet)) !void {
    state.calls += 1;
    for (0..state.items) |i| {
        try output.push(.{ .value = @intCast(i), .evaluations = &state.evaluations });
        state.produced += 1;
    }
}

pub fn mix(packet: Packet) u64 {
    packet.evaluations.* += 1;
    // Wrapping deterministic arithmetic; no random source or input allocation.
    return (packet.value *% 0x9e3779b97f4a7c15) ^ 0xa0761d6478bd642f;
}

pub fn keepEven(value: u64) bool {
    return value & 1 == 0;
}

pub fn finish(value: u64) u64 {
    return std.math.rotl(u64, value, 17) +% 3;
}

pub fn otherFinish(value: u64) u64 {
    return std.math.rotr(u64, value, 11) ^ 0xe7037ed1a0b428db;
}

pub fn execute(
    comptime shape: Shape,
    comptime variant: Variant,
    allocator: std.mem.Allocator,
    io: std.Io,
    items: usize,
    capacity: usize,
) !Result {
    return executeObserved(shape, variant, allocator, io, items, capacity, api.Noop{});
}

// Same declarations/callbacks as the elapsed/allocator passes. Observer changes
// only the private execution entry point; no per-item callback instrumentation.
pub fn executeObserved(
    comptime shape: Shape,
    comptime variant: Variant,
    allocator: std.mem.Allocator,
    io: std.Io,
    items: usize,
    capacity: usize,
    observer: anytype,
) !Result {
    var state: Producer = .{ .items = items };
    var left: Sink = .{};
    var right: Sink = .{};
    if (variant == .direct) {
        state.calls += 1;
        for (0..items) |i| {
            const value = mix(.{ .value = @intCast(i), .evaluations = &state.evaluations });
            state.produced += 1;
            if (keepEven(value)) left.accept(finish(value));
            if (shape == .fanout) right.accept(otherFinish(value));
        }
    } else if (variant == .graph) {
        const source: Stream(Packet) = .fromProducerWith(capacity, produce, &state);
        const mixed = pipe(&source, .{each(mix)});
        const left_flow = pipe(&mixed, .{
            filter(keepEven),
            each(finish),
            forEachWith(&left, Sink.accept),
        });
        if (shape == .linear) {
            if (@TypeOf(observer) == api.Noop) try zrx.run(allocator, io, .{left_flow}) else try api.legacyRunObserved(allocator, io, .{left_flow}, observer);
        } else {
            const right_flow = pipe(&mixed, .{
                each(otherFinish),
                forEachWith(&right, Sink.accept),
            });
            if (@TypeOf(observer) == api.Noop) try zrx.run(allocator, io, .{ left_flow, right_flow }) else try api.legacyRunObserved(allocator, io, .{ left_flow, right_flow }, observer);
        }
    } else {
        const source = current.Stream(Packet).fromProducer(capacity, produce);
        const mixed = currentPipe(&source, .{currentEach(mix)});
        const left_flow = currentPipe(&mixed, .{
            currentFilter(keepEven), currentEach(finish), currentForEach(acceptLeft),
        });
        const bindings = .{ allocator, io, &state, LeftSink{ .value = &left }, RightSink{ .value = &right } };
        if (shape == .linear) {
            if (@TypeOf(observer) == api.Noop) try current.run(bindings, .{left_flow}) else try api.runObserved(bindings, .{left_flow}, observer);
        } else {
            const right_flow = currentPipe(&mixed, .{ currentEach(otherFinish), currentForEach(acceptRight) });
            if (@TypeOf(observer) == api.Noop) try current.run(bindings, .{ left_flow, right_flow }) else try api.runObserved(bindings, .{ left_flow, right_flow }, observer);
        }
    }
    return .{
        .calls = state.calls,
        .produced = state.produced,
        .evaluations = state.evaluations,
        .left = left,
        .right = right,
    };
}

pub fn verify(comptime shape: Shape, items: usize, expected: Result, actual: Result) !void {
    if (actual.calls != 1 or actual.produced != items or actual.evaluations != items or
        actual.left.count != items / 2 or
        actual.right.count != (if (shape == .fanout) items else @as(usize, 0)) or
        !std.meta.eql(expected, actual))
        return error.IncorrectBenchmarkResult;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 5) return error.ExpectedItemsWarmupsTrialsCapacity;
    const items = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 4096;
    const warmups = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 2;
    const trials = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 7;
    const capacity = if (args.len > 4) try std.fmt.parseInt(usize, args[4], 10) else 16;
    if (warmups == 0 or trials == 0 or capacity == 0) return error.ExpectedPositiveOptions;

    // Thread-safe standard allocator. No benchmark allocator instrumentation.
    const allocator = std.heap.smp_allocator;
    var backend: std.Io.Threaded = .init(allocator, .{
        .async_limit = .nothing,
        .concurrent_limit = .unlimited,
    });
    defer backend.deinit();
    const io = backend.io();
    std.debug.print(
        "# zig={s} backend={s} optimize={s} arch={s} os={s} abi={s} cpu={s}\n" ++
            "# io=std.Io.Threaded async=nothing concurrent=unlimited allocator=smp_allocator clock=awake\n" ++
            "# graph=legacy-materialized current=declarative-fused\n" ++
            "# items={d} warmups={d} trials={d} capacity={d} packet_bytes={d} value_bytes={d}\n",
        .{
            builtin.zig_version_string,
            @tagName(builtin.zig_backend),
            @tagName(builtin.mode),
            @tagName(builtin.cpu.arch),
            @tagName(builtin.os.tag),
            @tagName(builtin.abi),
            builtin.cpu.model.name,
            items,
            warmups,
            trials,
            capacity,
            @sizeOf(Packet),
            @sizeOf(u64),
        },
    );
    std.debug.print("shape,variant,trial,elapsed_ns,producer_calls,produced,mix_evaluations,left_count,left_hash,right_count,right_hash\n", .{});

    inline for (.{ Shape.linear, Shape.fanout }) |shape| {
        // Empty/odd/even fixture checks are outside the measured interval.
        for ([_]usize{ 0, 1, 7, 32 }) |n| {
            const expected = try execute(shape, .direct, allocator, io, n, capacity);
            try verify(shape, n, expected, try execute(shape, .graph, allocator, io, n, capacity));
            try verify(shape, n, expected, try execute(shape, .current, allocator, io, n, capacity));
        }
        const expected = try execute(shape, .direct, allocator, io, items, capacity);
        for (0..warmups) |_| {
            inline for (.{ Variant.direct, Variant.graph, Variant.current }) |variant| {
                try verify(shape, items, expected, try execute(shape, variant, allocator, io, items, capacity));
            }
        }
        // Rotate all three variants, avoiding a fixed first position.
        for (0..trials) |trial| {
            inline for (0..3) |slot| {
                switch ((trial + slot) % 3) {
                    0 => try measure(shape, .direct, allocator, io, items, capacity, trial, expected),
                    1 => try measure(shape, .graph, allocator, io, items, capacity, trial, expected),
                    2 => try measure(shape, .current, allocator, io, items, capacity, trial, expected),
                    else => unreachable,
                }
            }
        }
    }
}

fn measure(
    comptime shape: Shape,
    comptime variant: Variant,
    allocator: std.mem.Allocator,
    io: std.Io,
    items: usize,
    capacity: usize,
    trial: usize,
    expected: Result,
) !void {
    const start = std.Io.Clock.awake.now(io);
    const actual = try execute(shape, variant, allocator, io, items, capacity);
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
    try verify(shape, items, expected, actual);
    std.debug.print("{s},{s},{d},{d},{d},{d},{d},{d},{x},{d},{x}\n", .{
        @tagName(shape),  @tagName(variant),  trial,              elapsed,
        actual.calls,     actual.produced,    actual.evaluations, actual.left.count,
        actual.left.hash, actual.right.count, actual.right.hash,
    });
}
