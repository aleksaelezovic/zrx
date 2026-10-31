const std = @import("std");
const world = @import("zrx");
const example = @import("world_example");
const loop_fixture = @import("world_loop.zig");
const pipe = world.pipe;
const fromSlice = world.fromSlice;
const each = world.each;
const forEach = world.forEach;
const resource = world.resource;
const deriveResource = world.deriveResource;
const run = world.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

test "public API exposes one declaration-only surface without With variants" {
    inline for (.{ "tryPipe", "tryFold", "keepIf", "tapWith", "forEachWith", "collectThenWith", "batchThenWith" }) |name|
        try std.testing.expect(!@hasDecl(world, name));
    try std.testing.expect(!@hasDecl(world.Stream(u32), "fromProducerWith"));
}

test "unreachable large recipe results reserve no run-owned value storage" {
    const Huge = [16 * 1024 * 1024]u8;
    const Functions = struct {
        fn acquire(_: void) Huge {
            @panic("unreachable recipe acquired");
        }
        fn release(_: Huge) void {
            @panic("unreachable recipe released");
        }
        fn save(output: *u32, value: u32) void {
            output.* = value;
        }
    };
    var output: u32 = 0;
    try run(.{ allocator, io, &output, resource({}, Functions.acquire, Functions.release) }, .{
        pipe(world.fromValue(@as(u32, 7)), .{forEach(Functions.save)}),
    });
    try std.testing.expectEqual(@as(u32, 7), output);
}

test "trailing data arguments never become injection requests of the same type" {
    const Functions = struct {
        fn add(service: u32, value: u32) u32 {
            return service + value;
        }
        fn save(output: *u32, value: u32) void {
            output.* = value;
        }
    };
    var result: u32 = 0;
    try run(.{ allocator, io, @as(u32, 100), &result }, .{
        pipe(world.fromValue(@as(u32, 5)), .{ world.map(Functions.add), world.forEach(Functions.save) }),
    });
    try std.testing.expectEqual(@as(u32, 105), result);
}

test "optional results are deliveries not end markers and literal fold seeds coerce" {
    const Functions = struct {
        fn optional(value: u32) ?u32 {
            return if (value == 2) null else value;
        }
        fn count(state: u64, _: ?u32) u64 {
            return state + 1;
        }
        fn save(output: *u64, value: u64) void {
            output.* = value;
        }
    };
    var count: u64 = 0;
    try run(.{ allocator, io, &count }, .{
        pipe(fromSlice(&[_]u32{ 1, 2, 3 }), .{
            world.map(Functions.optional),
            world.fold(0, Functions.count),
            world.forEach(Functions.save),
        }),
    });
    try std.testing.expectEqual(@as(u64, 3), count);
}

test "borrowed iterator reduction stops on reducer error without another probe" {
    const Iterator = struct {
        probes: usize = 0,
        pub fn next(self: *@This()) ?u32 {
            self.probes += 1;
            return @intCast(self.probes);
        }
    };
    const Functions = struct {
        fn add(state: u64, value: u32) !u64 {
            if (value == 2) return error.ReduceFailed;
            return state + value;
        }
        fn save(output: *u64, value: u64) void {
            output.* = value;
        }
    };
    var input: Iterator = .{};
    var output: u64 = 123;
    try std.testing.expectError(error.ReduceFailed, run(.{ allocator, io, &output }, .{
        pipe(world.fromIterator(&input), .{ world.fold(0, Functions.add), forEach(Functions.save) }),
    }));
    try std.testing.expectEqual(@as(usize, 2), input.probes);
    try std.testing.expectEqual(@as(u64, 123), output);
}

test "grouped and separate transformations share injected typed composition" {
    const Scale = struct { factor: u32 };
    const Bias = struct { value: u64 };
    const Functions = struct {
        fn scale(factor: Scale, value: u32) u64 {
            return @as(u64, value) * factor.factor;
        }
        fn bias(offset: Bias, value: u64) u64 {
            return value + offset.value;
        }
        fn save(output: *u64, value: u64) void {
            output.* = value;
        }
    };
    var output: u64 = 0;
    const bindings = .{ allocator, io, Scale{ .factor = 3 }, Bias{ .value = 2 }, &output };
    try run(bindings, .{
        pipe(world.fromValue(@as(u32, 5)), .{ world.map(.{ Functions.scale, Functions.bias }), forEach(Functions.save) }),
    });
    const grouped = output;
    output = 0;
    try run(bindings, .{
        pipe(world.fromValue(@as(u32, 5)), .{ world.map(Functions.scale), world.map(Functions.bias), forEach(Functions.save) }),
    });
    try std.testing.expectEqual(@as(u64, 17), grouped);
    try std.testing.expectEqual(grouped, output);
}

test "fallible filter errors stop later effects" {
    const Functions = struct {
        fn select(value: u32) !bool {
            if (value == 2) return error.SelectFailed;
            return true;
        }
        fn add(total: *u32, value: u32) void {
            total.* += value;
        }
    };
    var total: u32 = 0;
    try std.testing.expectError(error.SelectFailed, run(.{ allocator, io, &total }, .{
        pipe(fromSlice(&[_]u32{ 1, 2, 3 }), .{ world.filter(Functions.select), forEach(Functions.add) }),
    }));
    try std.testing.expectEqual(@as(u32, 1), total);
}

test "example stays cold and both database roles acquire fresh instances on each run" {
    var report: example.Report = .{};
    var items = [_]u32{ 1, 2, 3 };
    const flow = example.program(&items);
    const primary = deriveResource(example.PrimaryDatabase, example.database(.{ .kind = .primary, .scale = 2 }));
    const audit = deriveResource(example.AuditDatabase, example.database(.{ .kind = .audit, .scale = 1 }));
    try std.testing.expectEqual(@as(usize, 0), report.acquired);
    items[0] = 4; // The declaration borrows storage; it did not evaluate/copy input.
    try run(.{ audit, &report, io, primary, allocator }, .{flow});
    try std.testing.expectEqual(@as(u64, 9), report.primary_total);
    try std.testing.expectEqual(@as(u64, 18), report.audit_total);
    try std.testing.expectEqual(@as(usize, 2), report.acquired);
    try std.testing.expectEqual(@as(usize, 2), report.released);
    // Reordering bindings does not change resolution; resources do not replay.
    try run(.{ allocator, primary, &report, audit, io }, .{flow});
    try std.testing.expectEqual(@as(u64, 9), report.primary_total);
    try std.testing.expectEqual(@as(u64, 18), report.audit_total);
    try std.testing.expectEqual(@as(usize, 4), report.acquired);
    try std.testing.expectEqual(@as(usize, 4), report.released);
}

test "managed bindings acquire once across multiple terminal roots" {
    var report: example.Report = .{};
    const flow = example.program(&.{ 1, 2, 3 });
    try run(.{
        allocator,
        io,
        &report,
        deriveResource(example.PrimaryDatabase, example.database(.{ .kind = .primary, .scale = 2 })),
        deriveResource(example.AuditDatabase, example.database(.{ .kind = .audit, .scale = 1 })),
    }, .{ flow, flow });
    try std.testing.expectEqual(@as(u64, 12), report.primary_total);
    try std.testing.expectEqual(@as(u64, 24), report.audit_total);
    try std.testing.expectEqual(@as(usize, 2), report.acquired);
    try std.testing.expectEqual(@as(usize, 2), report.released);
}

const State = struct {
    events: [64]u8 = undefined,
    len: usize = 0,
    values: [8]u64 = undefined,
    count: usize = 0,
    live: usize = 0,
    parent_alive: bool = false,
    marker_alive: bool = false,
    order_ok: bool = true,
    fail_acquire: bool = false,
    block_acquire: bool = false,
    fail_transform: bool = false,
    fail_effect: bool = false,
    entered: std.Io.Event = .unset,
    gate: std.Io.Event = .unset,

    fn log(self: *State, event: u8) void {
        self.events[self.len] = event;
        self.len += 1;
    }
};
const Cell = struct { id: u8, parent: ?*Cell = null };
const Parent = struct { value: *Cell };
const Child = struct { value: *Cell };
const Marker = struct { id: u8 };
const Missing = struct {};
const Unused = struct {};
fn acquireParent(gpa: std.mem.Allocator, trace: *State, id: u8) !*Cell {
    const cell = try gpa.create(Cell);
    cell.* = .{ .id = id };
    trace.live += 1;
    trace.parent_alive = true;
    trace.log(id);
    return cell;
}

fn releaseParent(gpa: std.mem.Allocator, trace: *State, cell: *Cell) void {
    trace.parent_alive = false;
    trace.live -= 1;
    trace.log(10 + cell.id);
    gpa.destroy(cell);
}

fn acquireMarker(trace: *State, id: u8) Marker {
    trace.marker_alive = true;
    trace.log(id);
    return .{ .id = id };
}

fn releaseMarker(trace: *State, marker: Marker) void {
    trace.marker_alive = false;
    trace.log(10 + marker.id);
}

fn acquireChild(gpa: std.mem.Allocator, resource_io: std.Io, trace: *State, parent: Parent, id: u8) !*Cell {
    const cell = try gpa.create(Cell);
    errdefer gpa.destroy(cell);
    if (trace.block_acquire) {
        trace.entered.set(resource_io);
        try trace.gate.wait(resource_io);
    }
    if (trace.fail_acquire) {
        trace.log(9);
        return error.AcquireFailed; // Own the failed constructor's partial allocation.
    }
    cell.* = .{ .id = id, .parent = parent.value };
    trace.live += 1;
    trace.log(id);
    return cell;
}

fn releaseChild(gpa: std.mem.Allocator, trace: *State, marker: Marker, parent: Parent, cell: *Cell) void {
    // Marker is needed only during release; it must still be acquired before
    // Child, and must remain alive until after Child has released.
    trace.order_ok = trace.order_ok and trace.parent_alive and trace.marker_alive and
        marker.id == 3 and cell.parent == parent.value;
    trace.live -= 1;
    trace.log(10 + cell.id);
    gpa.destroy(cell);
}

fn acquireUnused(_: Missing, _: u8) Unused {
    return .{};
}

fn releaseUnused(_: Unused) void {}

fn transform(trace: *State, child: Child, same_child: Child, value: u32) !u64 {
    try std.testing.expect(child.value == same_child.value);
    trace.log(@intCast(20 + value));
    if (trace.fail_transform and value == 2) return error.TransformFailed;
    return @as(u64, value) * 10;
}

fn record(trace: *State, value: u64) !void {
    trace.log(@intCast(30 + value / 10));
    if (trace.fail_effect and value == 20) return error.EffectFailed;
    trace.values[trace.count] = value;
    trace.count += 1;
}

fn scenario(gpa: std.mem.Allocator, resource_io: std.Io, state: *State, input: []const u32, comptime effect: anytype) !void {
    try run(.{
        deriveResource(Child, resource(@as(u8, 2), acquireChild, releaseChild)),
        resource(@as(u8, 99), acquireUnused, releaseUnused),
        resource_io,
        state,
        deriveResource(Parent, resource(@as(u8, 1), acquireParent, releaseParent)),
        resource(@as(u8, 3), acquireMarker, releaseMarker),
        gpa,
    }, .{pipe(fromSlice(input), .{ each(transform), forEach(effect) })});
}

fn expectClean(state: *State) !void {
    try std.testing.expectEqual(@as(usize, 0), state.live);
    try std.testing.expect(!state.parent_alive and !state.marker_alive and state.order_ok);
}

test "dependency order includes release-only requirements and callbacks compose per item" {
    var state: State = .{};
    try scenario(allocator, io, &state, &.{ 1, 2, 3 }, record);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 2, 21, 31, 22, 32, 23, 33, 12, 13, 11 }, state.events[0..state.len]);
    try std.testing.expectEqualSlices(u64, &.{ 10, 20, 30 }, state.values[0..state.count]);
    try expectClean(&state);
}

test "empty input still acquires selected dependencies and invokes no callbacks" {
    var state: State = .{};
    try scenario(allocator, io, &state, &.{}, record);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 2, 12, 13, 11 }, state.events[0..state.len]);
    try std.testing.expectEqual(@as(usize, 0), state.count);
    try expectClean(&state);
}

test "acquisition failure cleans partial constructor work and earlier services before effects" {
    var state: State = .{ .fail_acquire = true };
    try std.testing.expectError(error.AcquireFailed, scenario(allocator, io, &state, &.{ 1, 2, 3 }, record));
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 9, 13, 11 }, state.events[0..state.len]);
    try std.testing.expectEqual(@as(usize, 0), state.count);
    try expectClean(&state);
}

test "transform and terminal failures stop later work without rolling back earlier effects" {
    for ([_]bool{ true, false }) |transform_failure| {
        var state: State = .{
            .fail_transform = transform_failure,
            .fail_effect = !transform_failure,
        };
        try std.testing.expectError(
            if (transform_failure) error.TransformFailed else error.EffectFailed,
            scenario(allocator, io, &state, &.{ 1, 2, 3 }, record),
        );
        try std.testing.expectEqualSlices(u64, &.{10}, state.values[0..state.count]);
        try std.testing.expectEqualSlices(u8, &.{ 12, 13, 11 }, state.events[state.len - 3 .. state.len]);
        try expectClean(&state);
    }
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    var state: State = .{};
    const result = scenario(gpa, io, &state, &.{ 1, 2, 3 }, record);
    try expectClean(&state);
    try result;
}

test "every recipe allocation failure releases earlier initialized resources" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}

test "borrowed bindings are not destroyed and are shared across selected terminal roots" {
    const Helpers = struct {
        fn add(total: *u32, value: u32) void {
            total.* += value;
        }
    };
    var total: u32 = 0;
    const flow = pipe(fromSlice(&[_]u32{ 1, 2 }), .{forEach(Helpers.add)});
    try run(.{ &total, io, allocator }, .{ flow, flow });
    try std.testing.expectEqual(@as(u32, 6), total);
    total += 1; // Still caller-owned and usable after the world has ended.
    try std.testing.expectEqual(@as(u32, 7), total);
}

test "declared inputs retain optional data and callbacks use normal argument coercions" {
    const Helpers = struct {
        fn recover(value: ?u16) u32 {
            return value orelse 7;
        }
        fn widen(value: u64) u128 {
            return value * 2;
        }
        fn add(total: *u128, value: u128) void {
            total.* += value;
        }
    };
    var total: u128 = 0;
    const items = [_]?u16{ 1, null, 3 };
    const flow = pipe(fromSlice(&items), .{
        each(Helpers.recover),
        each(Helpers.widen),
        forEach(Helpers.add),
    });
    try run(.{ allocator, io, &total }, .{flow});
    try std.testing.expectEqual(@as(u128, 22), total);
}

test "finite direct composition needs no allocator calls or concurrent task support" {
    const Helpers = struct {
        fn add(total: *u32, value: u32) void {
            total.* += value;
        }
    };
    var failing: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = 0 });
    // No task can start on this backend. The world does not need one.
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .nothing, .async_limit = .nothing });
    defer backend.deinit();
    var total: u32 = 0;
    const source = fromSlice(&[_]u32{ 1, 2 });
    const named = pipe(&source, .{each(struct {
        fn identity(value: u32) u32 {
            return value;
        }
    }.identity)});
    const flow = pipe(&named, .{forEach(Helpers.add)});
    try run(.{ failing.allocator(), backend.io(), &total }, .{flow});
    try std.testing.expectEqual(@as(u32, 3), total);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "runtime-input codegen fixture executes the declared transform and terminal" {
    const input = [_]u32{ 0, 1, 7, std.math.maxInt(u32) };
    var total: u64 = std.math.maxInt(u64);
    try std.testing.expect(loop_fixture.world_finite_loop(&io, &input, input.len, &total));
    var expected: u64 = std.math.maxInt(u64);
    for (input) |value| expected +%= @as(u64, value) * 3 + 1;
    try std.testing.expectEqual(expected, total);
    var direct: u64 = std.math.maxInt(u64);
    try std.testing.expect(loop_fixture.direct_finite_loop(&io, &input, input.len, &direct));
    try std.testing.expectEqual(expected, direct);
    try std.testing.expect(loop_fixture.world_finite_loop(&io, &input, 0, &total));
    try std.testing.expect(loop_fixture.direct_finite_loop(&io, &input, 0, &direct));
    try std.testing.expectEqual(expected, total);
    try std.testing.expectEqual(expected, direct);
}

test "cancellation during acquisition frees partial work and releases earlier resources" {
    const Helpers = struct {
        fn execute(state: *State) !void {
            try scenario(allocator, io, state, &.{1}, record);
        }
    };
    var state: State = .{ .block_acquire = true };
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try state.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try expectClean(&state);
    try std.testing.expectEqual(@as(usize, 0), state.count);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 13, 11 }, state.events[0..state.len]);
}

test "parent cancellation exits the active callback before resource release" {
    const Helpers = struct {
        fn block(trace: *State, resource_io: std.Io, _: u64) !void {
            trace.entered.set(resource_io);
            try trace.gate.wait(resource_io);
        }
        fn execute(state: *State) !void {
            try scenario(allocator, io, state, &.{1}, block);
        }
    };
    var state: State = .{};
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try state.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try expectClean(&state);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 2, 21, 12, 13, 11 }, state.events[0..state.len]);
}
