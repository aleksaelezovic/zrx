const std = @import("std");
const zrx = @import("zrx");
const app = @import("app");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const map = zrx.map;
const queue = zrx.queue;
const batch = zrx.batch;
const flatten = zrx.flatten;
const forEach = zrx.forEach;

const Mode = enum { loop, sync, per_item, batched };
const Profile = enum { small, standard, large };
const Config = struct {
    records: usize,
    detail_bytes: usize = 0,
    sink_us: u32 = 0,
    source_us: u32 = 0,
};

const Raw = struct { line: app.records.Line, start: ?Io.Timestamp };
const Item = struct { cleaned: app.records.Record, start: ?Io.Timestamp };

const DigestSink = struct {
    writer: Io.Writer,
    io: Io,
    delay_us: u32,
    hash: Sha256 = .init(.{}),
    bytes: usize = 0,
    drains: usize = 0,

    fn drain(w: *Io.Writer, parts: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const sink: *DigestSink = @alignCast(@fieldParentPtr("writer", w));
        if (sink.delay_us != 0) sink.io.sleep(.fromMicroseconds(sink.delay_us), .awake) catch
            return error.WriteFailed;
        sink.drains += 1;
        sink.hash.update(w.buffered());
        sink.bytes += w.end;
        w.end = 0;
        var consumed: usize = 0;
        for (parts[0 .. parts.len - 1]) |part| {
            sink.hash.update(part);
            consumed += part.len;
        }
        for (0..splat) |_| {
            const part = parts[parts.len - 1];
            sink.hash.update(part);
            consumed += part.len;
        }
        sink.bytes += consumed;
        return consumed;
    }
};

// Count successful allocations requested through the Threaded backend's
// allocator. Thread stack mappings and allocator bookkeeping sit outside it.
const RuntimeAllocations = struct {
    count: std.atomic.Value(usize) = .init(0),
    bytes: std.atomic.Value(usize) = .init(0),
    const backing = std.heap.smp_allocator;
    const Allocator = std.mem.Allocator;

    fn allocator(self: *RuntimeAllocations) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = Allocator.noResize,
            .remap = Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *RuntimeAllocations = @ptrCast(@alignCast(ctx));
        const mem = backing.rawAlloc(len, alignment, address) orelse return null;
        _ = self.count.fetchAdd(1, .monotonic);
        _ = self.bytes.fetchAdd(len, .monotonic);
        return mem;
    }

    fn free(_: *anyopaque, mem: []u8, alignment: std.mem.Alignment, address: usize) void {
        backing.rawFree(mem, alignment, address);
    }
};

const Wait = struct {
    count: usize = 0,
    ns: u64 = 0,
};

// The benchmark runs a single variant per process. The probe samples only
// futex calls made by the source while it is submitting a record.
var base_io: Io = undefined;
threadlocal var waits: ?*Wait = null;

fn observeWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    const observed = waits orelse return base_io.vtable.futexWait(userdata, ptr, expected, timeout);
    const before = Io.Clock.awake.now(base_io);
    defer {
        observed.count += 1;
        observed.ns += @intCast(before.durationTo(Io.Clock.awake.now(base_io)).nanoseconds);
    }
    return base_io.vtable.futexWait(userdata, ptr, expected, timeout);
}

const Histogram = struct {
    buckets: [64]usize = @splat(0),
    total: usize = 0,

    fn sample(self: *Histogram, ns: u64) void {
        self.buckets[63 - @clz(@max(ns, 1))] += 1;
        self.total += 1;
    }

    fn upperBound(self: *const Histogram, percent: usize) u64 {
        const rank = (self.total * percent + 99) / 100;
        var n: usize = 0;
        for (self.buckets, 0..) |count, i| {
            n += count;
            if (n >= rank) return @as(u64, std.math.maxInt(u64)) >> @as(u6, @intCast(63 - i));
        }
        unreachable;
    }
};

const Run = struct {
    io: Io,
    config: Config,
    template: app.records.Line,
    trace_queue: bool,
    sink: *DigestSink,
    producer_wait: Wait = .{},
    latency: Histogram = .{},

    fn produce(self: *Run, out: anytype) !void {
        // Sample up to roughly 4K records per run using the same indices.
        const step = @max(1, (self.config.records + 4095) / 4096);
        for (0..self.config.records) |i| {
            if (i != 0 and i % 64 == 0 and self.config.source_us != 0)
                try self.io.sleep(.fromMicroseconds(self.config.source_us), .awake);
            var line = self.template;
            // Fixed-width decimal IDs make the checksum detect missing items
            // and reordering. The configured record cap keeps this ten digits.
            _ = try std.fmt.bufPrint(line.bytes[6..][0..10], "{d}", .{1_000_000_000 + i});
            const start = if (i % step == 0) Io.Clock.awake.now(self.io) else null;
            waits = if (self.trace_queue) &self.producer_wait else null;
            defer waits = null;
            if (try out.push(Raw{ .line = line, .start = start }) == .done) return;
        }
    }

    fn redact(raw: Raw) !Item {
        return .{ .cleaned = try app.records.redact(raw.line), .start = raw.start };
    }

    fn encode(self: *Run, item: Item) !void {
        try item.cleaned.write(&self.sink.writer);
        if (item.start) |start| self.latency.sample(@intCast(start.durationTo(Io.Clock.awake.now(self.io)).nanoseconds));
    }

    const Loop = struct {
        run: *Run,

        pub fn push(self: Loop, raw: Raw) !zrx.Flow {
            try self.run.encode(try redact(raw));
            return .more;
        }
    };
};

const Result = struct {
    hash: [Sha256.digest_length]u8,
    bytes: usize,
    drains: usize,
    ns: u64,
    latency_p50_ns: u64,
    latency_p95_ns: u64,
    latency_p99_ns: u64,
    producer_wait: Wait,
    queue_bytes: usize,
    staging_bytes: usize,
};

fn measure(io: Io, mode: Mode, config: Config, comptime width: usize, comptime depth: usize) !Result {
    var output_buffer: [app.output_buffer_bytes]u8 = undefined;
    var buffer: [app.records.max_line]u8 = @splat('x');
    var input: app.records.Line = .{ .bytes = undefined, .len = 0 };
    input.len = (try std.fmt.bufPrint(
        &input.bytes,
        "{{\"id\":1000000000,\"ts_ms\":1710000000000,\"action\":\"update\",\"resource\":\"warehouse-12\",\"actor\":\"operator\",\"detail\":\"{s}\"}}",
        .{buffer[0..config.detail_bytes]},
    )).len;
    var sink: DigestSink = .{
        .writer = .{ .buffer = &output_buffer, .vtable = &.{ .drain = DigestSink.drain } },
        .io = io,
        .delay_us = config.sink_us,
    };
    var run: Run = .{
        .io = io,
        .config = config,
        .template = input,
        .trace_queue = mode == .per_item or mode == .batched,
        .sink = &sink,
    };
    const Group = zrx.Batch(Item, width);
    // Round down to whole items. The two queue variants differ by less than
    // one item of reserved ring storage.
    const item_slots = depth * @sizeOf(Group) / @sizeOf(Item);
    var vtable = io.vtable.*;
    base_io = io;
    vtable.futexWait = observeWait;
    const observed: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    const source = zrx.fromProducer(Raw, Run.produce);
    const start = Io.Clock.awake.now(io);
    switch (mode) {
        .loop => try run.produce(Run.Loop{ .run = &run }),
        .sync => try zrx.program(source, .{
            map(Run.redact),
            forEach(Run.encode),
        }).run(.{&run}),
        .per_item => {
            var slots: [item_slots]Item = undefined;
            try zrx.program(source, .{
                map(Run.redact),
                queue(&slots),
                forEach(Run.encode),
            }).run(.{ observed, &run });
        },
        .batched => {
            var slots: [depth]Group = undefined;
            try zrx.program(source, .{
                map(Run.redact),
                batch(width),
                queue(&slots),
                flatten(),
                forEach(Run.encode),
            }).run(.{ observed, &run });
        },
    }
    try sink.writer.flush();
    return .{
        .hash = sink.hash.finalResult(),
        .bytes = sink.bytes,
        .drains = sink.drains,
        .ns = @intCast(start.durationTo(Io.Clock.awake.now(io)).nanoseconds),
        .latency_p50_ns = run.latency.upperBound(50),
        .latency_p95_ns = run.latency.upperBound(95),
        .latency_p99_ns = run.latency.upperBound(99),
        .producer_wait = run.producer_wait,
        .queue_bytes = switch (mode) {
            .loop, .sync => 0,
            .per_item => item_slots * @sizeOf(Item),
            .batched => depth * @sizeOf(Group),
        },
        .staging_bytes = if (mode == .batched) width * @sizeOf(Item) else 0,
    };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 7) return error.InvalidArguments;
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse return error.InvalidMode;
    const config: Config = .{
        .records = try std.fmt.parseInt(usize, args[2], 10),
        .detail_bytes = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 0,
        .sink_us = if (args.len > 4) try std.fmt.parseInt(u32, args[4], 10) else 0,
        .source_us = if (args.len > 5) try std.fmt.parseInt(u32, args[5], 10) else 0,
    };
    if (config.records == 0 or config.records > 10_000_000 or config.detail_bytes > 800)
        return error.InvalidSize;
    const profile = if (args.len > 6) std.meta.stringToEnum(Profile, args[6]) orelse return error.InvalidProfile else .standard;
    var allocations: RuntimeAllocations = .{};
    var runtime = Io.Threaded.init(allocations.allocator(), .{});
    defer runtime.deinit();
    const io = runtime.io();
    const result = switch (profile) {
        .small => try measure(io, mode, config, 8, 2),
        .standard => try measure(io, mode, config, 32, 4),
        .large => try measure(io, mode, config, 64, 8),
    };
    var scratch: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &scratch);
    const hex = std.fmt.bytesToHex(result.hash, .lower);
    const elapsed_s = @as(f64, @floatFromInt(@max(result.ns, 1))) / std.time.ns_per_s;
    try std.json.Stringify.value(.{
        .mode = mode,
        .profile = profile,
        .records = config.records,
        .detail_bytes = config.detail_bytes,
        .sink_us = config.sink_us,
        .source_us = config.source_us,
        .elapsed_ns = result.ns,
        .records_per_s = @as(f64, @floatFromInt(config.records)) / elapsed_s,
        .bytes = result.bytes,
        .sha256 = hex[0..],
        .drains = result.drains,
        .encode_p50_bound_ns = result.latency_p50_ns,
        .encode_p95_bound_ns = result.latency_p95_ns,
        .encode_p99_bound_ns = result.latency_p99_ns,
        .producer_futex_waits = result.producer_wait.count,
        .producer_futex_ns = result.producer_wait.ns,
        .queue_bytes = result.queue_bytes,
        .batch_staging_bytes = result.staging_bytes,
        .writer_buffer_bytes = app.output_buffer_bytes,
        .parser_scratch_bytes = app.records.scratch_bytes,
        .runtime_allocations = allocations.count.load(.monotonic),
        .runtime_allocated_bytes = allocations.bytes.load(.monotonic),
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

test "every benchmark shape performs identical work and flushes the final bytes" {
    const io = std.testing.io;
    const config: Config = .{ .records = 259, .detail_bytes = 800 };
    const baseline = try measure(io, .loop, config, 8, 2);
    for ([_]Mode{ .sync, .per_item, .batched }) |mode| {
        const compared = try measure(io, mode, config, 8, 2);
        try std.testing.expectEqual(baseline.hash, compared.hash);
        try std.testing.expectEqual(baseline.bytes, compared.bytes);
        try std.testing.expectEqual(baseline.drains, compared.drains);
    }
}
