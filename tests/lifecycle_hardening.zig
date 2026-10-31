const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const run = zrx.run;
const fromSlice = zrx.fromSlice;
const each = zrx.each;
const forEach = zrx.forEach;
const collectThen = zrx.collectThen;
const take = zrx.take;
const resource = zrx.resource;
const allocator = std.testing.allocator;
const io = std.testing.io;

const Saved = struct { items: [8]u32 = undefined, len: usize = 0 };
const Left = struct { value: *Saved };
const Right = struct { value: *Saved };
const AliasProbe = struct {
    live: std.atomic.Value(bool) = .init(false),
    late: std.atomic.Value(bool) = .init(false),
    small: std.atomic.Value(usize) = .init(0),
    large: std.atomic.Value(usize) = .init(0),
    effects: std.atomic.Value(usize) = .init(0),
    acquired: usize = 0,
    released: usize = 0,
    effects_at_release: usize = 0,
};
const AliasOwner = struct { probe: *AliasProbe };
fn acquireAlias(probe: *AliasProbe, _: void) AliasOwner {
    probe.acquired += 1;
    probe.live.store(true, .release);
    return .{ .probe = probe };
}
fn releaseAlias(owner: AliasOwner) void {
    owner.probe.effects_at_release = owner.probe.effects.load(.acquire);
    owner.probe.live.store(false, .release);
    owner.probe.released += 1;
}
fn guardAlias(owner: AliasOwner) void {
    if (!owner.probe.live.load(.acquire)) owner.probe.late.store(true, .release);
}
fn evaluate(owner: AliasOwner, value: u32) u32 {
    guardAlias(owner);
    if (value < 10)
        _ = owner.probe.small.fetchAdd(1, .monotonic)
    else
        _ = owner.probe.large.fetchAdd(1, .monotonic);
    return value * 2;
}
fn saveLeft(owner: AliasOwner, output: Left, items: []const u32) void {
    guardAlias(owner);
    @memcpy(output.value.items[0..items.len], items);
    output.value.len = items.len;
    _ = owner.probe.effects.fetchAdd(1, .release);
}
fn saveRight(owner: AliasOwner, output: Right, items: []const u32) void {
    guardAlias(owner);
    @memcpy(output.value.items[0..items.len], items);
    output.value.len = items.len;
    _ = owner.probe.effects.fetchAdd(1, .release);
}

test "runtime aliases switch between shared and distinct same-type declarations across runs" {
    const first_input = fromSlice(@as([]const u32, &.{ 1, 2, 3, 4 }));
    const second_input = fromSlice(@as([]const u32, &.{ 10, 20, 30, 40 }));
    var first = pipe(&first_input, .{each(evaluate)});
    const second = pipe(&second_input, .{each(evaluate)});
    for ([_]bool{ true, false, true }) |same| {
        var probe: AliasProbe = .{};
        var left: Saved = .{};
        var right: Saved = .{};
        // One type/shape, different runtime identities. The left reference is
        // mutable and the selected right reference is const-qualified.
        const chosen: *const @TypeOf(first) = if (same) &first else &second;
        try run(.{
            allocator,                                io, &probe, Left{ .value = &left }, Right{ .value = &right },
            resource({}, acquireAlias, releaseAlias),
        }, .{
            pipe(&first, .{collectThen(saveLeft)}),
            pipe(chosen, .{collectThen(saveRight)}),
        });
        try std.testing.expectEqualSlices(u32, &.{ 2, 4, 6, 8 }, left.items[0..left.len]);
        try std.testing.expectEqualSlices(u32, if (same) &.{ 2, 4, 6, 8 } else &.{ 20, 40, 60, 80 }, right.items[0..right.len]);
        try std.testing.expectEqual(@as(usize, 4), probe.small.load(.acquire));
        try std.testing.expectEqual(@as(usize, if (same) 0 else 4), probe.large.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), probe.acquired);
        try std.testing.expectEqual(@as(usize, 1), probe.released);
        try std.testing.expectEqual(@as(usize, 2), probe.effects_at_release);
        try std.testing.expect(!probe.live.load(.acquire) and !probe.late.load(.acquire));
    }
}

const GroupProbe = struct {
    first_done: std.Io.Event = .unset,
    workers_started: std.atomic.Value(usize) = .init(0),
    workers_exited: std.atomic.Value(usize) = .init(0),
};
const CompletionProbe = struct {
    fail_peer: bool,
    group: GroupProbe = .{},
    never: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    prefix_calls: std.atomic.Value(usize) = .init(0),
    peer_calls: std.atomic.Value(usize) = .init(0),
    producer_stopped: std.atomic.Value(bool) = .init(false),
    released: bool = false,
    early: bool = false,
};
const CompletionOwner = struct { probe: *CompletionProbe };

const GroupObserver = struct {
    var current: *GroupProbe = undefined;
    const Proxy = struct {
        probe: *GroupProbe,
        index: usize,
        context: []u8,
        alignment: std.mem.Alignment,
        start: *const fn (*const anyopaque) void,
    };
    fn start(raw: *const anyopaque) void {
        const proxy = @as(*const *Proxy, @ptrCast(@alignCast(raw))).*;
        const probe = proxy.probe;
        const index = proxy.index;
        proxy.start(@ptrCast(proxy.context.ptr));
        allocator.rawFree(proxy.context, proxy.alignment, @returnAddress());
        allocator.destroy(proxy);
        _ = probe.workers_exited.fetchAdd(1, .release);
        // Worker.start has reported its result before returning here. Each
        // scenario expects its first worker to be a successful prefix; on that
        // path its delivery edge has also retired before this event.
        if (index == 0) probe.first_done.set(io);
    }
    fn concurrent(userdata: ?*anyopaque, group: *std.Io.Group, context: []const u8, alignment: std.mem.Alignment, original: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
        const proxy = allocator.create(Proxy) catch return error.ConcurrencyUnavailable;
        errdefer allocator.destroy(proxy);
        const memory = allocator.rawAlloc(context.len, alignment, @returnAddress()) orelse return error.ConcurrencyUnavailable;
        errdefer allocator.rawFree(memory[0..context.len], alignment, @returnAddress());
        @memcpy(memory[0..context.len], context);
        proxy.* = .{
            .probe = current,
            .index = current.workers_started.fetchAdd(1, .monotonic),
            .context = memory[0..context.len],
            .alignment = alignment,
            .start = original,
        };
        // The backend copies this pointer; the proxy owns its aligned copy of
        // the original context until the original worker returns.
        return io.vtable.groupConcurrent(userdata, group, std.mem.asBytes(&proxy), .of(*Proxy), start);
    }
};

fn acquireCompletion(probe: *CompletionProbe, _: void) CompletionOwner {
    return .{ .probe = probe };
}
fn releaseCompletion(owner: CompletionOwner) void {
    const probe = owner.probe;
    probe.early = !probe.producer_stopped.load(.acquire) or probe.group.workers_exited.load(.acquire) != 2;
    probe.released = true;
}
fn produceCompletion(owner: CompletionOwner, resource_io: std.Io, output: *zrx.Emitter(u32)) !void {
    defer owner.probe.producer_stopped.store(true, .release);
    try output.push(1);
    try owner.probe.group.first_done.wait(resource_io);
    try output.push(2);
    if (owner.probe.fail_peer) try owner.probe.never.wait(resource_io);
}
fn prefix(owner: CompletionOwner, _: u32) void {
    _ = owner.probe.prefix_calls.fetchAdd(1, .monotonic);
}
fn peer(owner: CompletionOwner, value: u32) !void {
    _ = owner.probe.peer_calls.fetchAdd(1, .monotonic);
    if (value == 2 and owner.probe.fail_peer) return error.PeerFailed;
}
fn executeCompletion(probe: *CompletionProbe) anyerror!void {
    defer probe.done.set(io);
    var table = io.vtable.*;
    table.groupConcurrent = GroupObserver.concurrent;
    const observed: std.Io = .{ .userdata = io.userdata, .vtable = &table };
    const source = zrx.Stream(u32).fromProducer(1, produceCompletion);
    try run(.{ allocator, observed, probe, resource({}, acquireCompletion, releaseCompletion) }, .{
        pipe(&source, .{ take(1), forEach(prefix) }),
        pipe(&source, .{forEach(peer)}),
    });
}

test "an already-completed prefix neither ends its peer early nor hides a later failure" {
    for ([_]bool{ false, true }) |failure| {
        var probe: CompletionProbe = .{ .fail_peer = failure };
        GroupObserver.current = &probe.group;
        var task = try io.concurrent(executeCompletion, .{&probe});
        defer task.cancel(io) catch {};
        try probe.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
        if (failure)
            try std.testing.expectError(error.PeerFailed, task.await(io))
        else
            try task.await(io);
        try std.testing.expectEqual(@as(usize, 1), probe.prefix_calls.load(.acquire));
        try std.testing.expectEqual(@as(usize, 2), probe.peer_calls.load(.acquire));
        try std.testing.expectEqual(@as(usize, 2), probe.group.workers_started.load(.acquire));
        try std.testing.expectEqual(@as(usize, 2), probe.group.workers_exited.load(.acquire));
        try std.testing.expect(probe.released and !probe.early);
    }
}

test "state failure after observation retirement fails an idle sampler before releasing services" {
    const Probe = struct {
        group: GroupProbe = .{},
        event_entered: std.Io.Event = .unset,
        never: std.Io.Event = .unset,
        done: std.Io.Event = .unset,
        live: std.atomic.Value(bool) = .init(false),
        late: std.atomic.Value(bool) = .init(false),
        update_calls: std.atomic.Value(usize) = .init(0),
        event_calls: std.atomic.Value(usize) = .init(0),
        maps: std.atomic.Value(usize) = .init(0),
        observations: std.atomic.Value(usize) = .init(0),
        sampled: std.atomic.Value(bool) = .init(false),
        updates_stopped: std.atomic.Value(bool) = .init(false),
        events_stopped: std.atomic.Value(bool) = .init(false),
        released: bool = false,
        early: bool = false,
    };
    const Owned = struct { probe: *Probe };
    const Helpers = struct {
        fn acquire(probe: *Probe, _: void) Owned {
            probe.live.store(true, .release);
            return .{ .probe = probe };
        }
        fn release(owned: Owned) void {
            const probe = owned.probe;
            probe.early = !probe.updates_stopped.load(.acquire) or !probe.events_stopped.load(.acquire) or
                probe.group.workers_exited.load(.acquire) != 2;
            probe.live.store(false, .release);
            probe.released = true;
        }
        fn guard(owned: Owned) void {
            if (!owned.probe.live.load(.acquire)) owned.probe.late.store(true, .release);
        }
        fn updates(owned: Owned, resource_io: std.Io, _: *zrx.Emitter(u32)) !void {
            guard(owned);
            _ = owned.probe.update_calls.fetchAdd(1, .monotonic);
            defer owned.probe.updates_stopped.store(true, .release);
            try owned.probe.group.first_done.wait(resource_io);
            try owned.probe.event_entered.wait(resource_io);
            return error.StateFailed;
        }
        fn events(owned: Owned, resource_io: std.Io, _: *zrx.Emitter(u32)) !void {
            guard(owned);
            _ = owned.probe.event_calls.fetchAdd(1, .monotonic);
            defer owned.probe.events_stopped.store(true, .release);
            owned.probe.event_entered.set(resource_io);
            try owned.probe.never.wait(resource_io);
        }
        fn derive(owned: Owned, value: u32) u32 {
            guard(owned);
            _ = owned.probe.maps.fetchAdd(1, .monotonic);
            return value + 1;
        }
        fn observe(owned: Owned, value: u32) !void {
            guard(owned);
            try std.testing.expectEqual(@as(u32, 11), value);
            _ = owned.probe.observations.fetchAdd(1, .monotonic);
        }
        fn unexpected(owned: Owned, _: struct { u32, u32 }) void {
            guard(owned);
            owned.probe.sampled.store(true, .release);
        }
        fn execute(probe: *Probe) anyerror!void {
            defer probe.done.set(io);
            var table = io.vtable.*;
            table.groupConcurrent = GroupObserver.concurrent;
            const observed: std.Io = .{ .userdata = io.userdata, .vtable = &table };
            const updates_source = zrx.Stream(u32).fromProducer(1, updates);
            const event_source = zrx.Stream(u32).fromProducer(1, events);
            const current = pipe(&updates_source, .{ zrx.hold(@as(u32, 10)), zrx.map(derive) });
            try run(.{ allocator, observed, probe, resource({}, acquire, release) }, .{
                pipe(zrx.values(&current), .{ take(1), forEach(observe) }),
                pipe(&event_source, .{ zrx.withLatestFrom(&current), forEach(unexpected) }),
            });
        }
    };
    var probe: Probe = .{};
    GroupObserver.current = &probe.group;
    var task = try io.concurrent(Helpers.execute, .{&probe});
    defer task.cancel(io) catch {};
    try probe.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try std.testing.expectError(error.StateFailed, task.await(io));
    try std.testing.expectEqual(@as(usize, 1), probe.update_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), probe.event_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), probe.maps.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), probe.observations.load(.acquire));
    try std.testing.expect(!probe.sampled.load(.acquire) and !probe.late.load(.acquire));
    try std.testing.expect(probe.released and !probe.early and !probe.live.load(.acquire));
}
