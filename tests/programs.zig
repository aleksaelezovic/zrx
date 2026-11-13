//! Sources, programs and systems.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");
const io = std.testing.io;

const pipe = zrx.pipe;
const program = zrx.program;
const system = zrx.system;
const fromSlice = zrx.fromSlice;
const fromValue = zrx.fromValue;
const range = zrx.range;
const fromIterator = zrx.fromIterator;
const fromProducer = zrx.fromProducer;
const merge = zrx.merge;
const map = zrx.map;
const fold = zrx.fold;
const take = zrx.take;
const queue = zrx.queue;
const subscribe = zrx.subscribe;

const Numbers = support.Recorder(u32);
const record = support.record(u32);

fn add(sum: u32, value: u32) u32 {
    return sum + value;
}

test "fromValue emits one item" {
    var seen: Numbers = .{};
    try program(fromValue(@as(u32, 42)), pipe(.{subscribe(record)})).run(.{&seen});
    try seen.expect(&.{42});
}

test "fromSlice accepts slices and array pointers" {
    var seen: Numbers = .{};
    const array = [_]u32{ 1, 2, 3 };
    const slice: []const u32 = array[1..];
    try program(fromSlice(&array), pipe(.{subscribe(record)})).run(.{&seen});
    try program(fromSlice(slice), pipe(.{subscribe(record)})).run(.{&seen});
    try seen.expect(&.{ 1, 2, 3, 2, 3 });
}

const Countdown = struct {
    left: u32,

    pub fn next(self: *Countdown) ?u32 {
        if (self.left == 0) return null;
        self.left -= 1;
        return self.left;
    }
};

test "fromIterator pulls until null and leaves the rest when stopped early" {
    var seen: Numbers = .{};
    var all: Countdown = .{ .left = 3 };
    try program(fromIterator(&all), pipe(.{subscribe(record)})).run(.{&seen});
    var some: Countdown = .{ .left = 10 };
    try program(fromIterator(&some), pipe(.{ take(2), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 2, 1, 0, 9, 8 });
    try std.testing.expectEqual(@as(u32, 8), some.left);
}

const Flaky = struct {
    calls: u32 = 0,

    pub fn next(self: *Flaky) error{Broken}!?u32 {
        self.calls += 1;
        if (self.calls == 3) return error.Broken;
        return self.calls;
    }
};

test "a failing iterator fails the run" {
    var seen: Numbers = .{};
    var flaky: Flaky = .{};
    try std.testing.expectError(error.Broken, program(fromIterator(&flaky), pipe(.{subscribe(record)})).run(.{&seen}));
    try seen.expect(&.{ 1, 2 });
}

const Start = struct { at: u32 };
fn countUp(start: Start, out: anytype) !void {
    var value = start.at;
    while (try out.push(value) == .more) value += 1;
}

test "fromProducer injects dependencies and stops when told" {
    var seen: Numbers = .{};
    try program(fromProducer(u32, countUp), pipe(.{ take(3), subscribe(record) })).run(.{ &seen, Start{ .at = 10 } });
    try seen.expect(&.{ 10, 11, 12 });
}

test "a program is a value: every run starts from fresh state" {
    var seen: Numbers = .{};
    const total = program(range(u32, 1, 4), pipe(.{ fold(@as(u32, 0), add), subscribe(record) }));
    try total.run(.{&seen});
    try total.run(.{&seen});
    try seen.expect(&.{ 6, 6 });
}

// --- merge ----------------------------------------------------------------

test "merge delivers every item of every source, each in its own order" {
    var seen: Numbers = .{};
    const low = [_]u32{ 1, 2, 3, 4 };
    const high = [_]u32{ 100, 200, 300 };
    try program(merge(.{ fromSlice(&low), fromSlice(&high) }), pipe(.{subscribe(record)})).run(.{ io, &seen });
    try std.testing.expectEqual(@as(usize, 7), seen.len);
    var last_low: u32 = 0;
    var last_high: u32 = 0;
    for (seen.slice()) |value| {
        if (value < 100) {
            try std.testing.expect(value > last_low);
            last_low = value;
        } else {
            try std.testing.expect(value > last_high);
            last_high = value;
        }
    }
    try std.testing.expectEqual(@as(u32, 4), last_low);
    try std.testing.expectEqual(@as(u32, 300), last_high);
}

test "merge stops every source when the pipe is done" {
    var seen: Numbers = .{};
    const endless = range(u32, 0, std.math.maxInt(u32));
    try program(merge(.{ endless, endless }), pipe(.{ take(5), subscribe(record) })).run(.{ io, &seen });
    try std.testing.expectEqual(@as(usize, 5), seen.len);
}

fn failAtTwo(value: u32) error{Two}!u32 {
    if (value == 2) return error.Two;
    return value;
}

test "a failure under merge fails the run" {
    var seen: Numbers = .{};
    const result = program(merge(.{ range(u32, 0, 100), range(u32, 0, 100) }), pipe(.{ map(failAtTwo), subscribe(record) })).run(.{ io, &seen });
    try std.testing.expectError(error.Two, result);
}

// --- system ---------------------------------------------------------------

const Left = struct { seen: *Numbers };
const Right = struct { seen: *Numbers };
fn toLeft(sink: Left, value: u32) void {
    sink.seen.add(value);
}
fn toRight(sink: Right, value: u32) void {
    sink.seen.add(value);
}

test "a system runs every program with the same dependencies" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const totals = program(range(u32, 1, 5), pipe(.{ fold(@as(u32, 0), add), subscribe(toLeft) }));
    const echo = program(range(u32, 7, 10), pipe(.{ queue(2), subscribe(toRight) }));
    try system(.{ totals, echo }).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{10});
    try right.expect(&.{ 7, 8, 9 });
}

test "systems nest, and a system of one needs no Io" {
    // Programs of a system run at the same time: each writes to its own log.
    var left: Numbers = .{};
    var right: Numbers = .{};
    var seen: Numbers = .{};
    const a = program(fromValue(@as(u32, 1)), pipe(.{subscribe(toLeft)}));
    const b = program(fromValue(@as(u32, 2)), pipe(.{subscribe(toRight)}));
    const c = program(fromValue(@as(u32, 3)), pipe(.{subscribe(record)}));
    try system(.{a}).run(.{Left{ .seen = &left }});
    try system(.{ system(.{a}), system(.{ b, c }) }).run(.{ io, &seen, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 1, 1 });
    try right.expect(&.{2});
    try seen.expect(&.{3});
}

fn patiently(clock: std.Io, out: anytype) !void {
    var value: u32 = 0;
    while (value < 200) : (value += 1) {
        try clock.sleep(.fromMilliseconds(1), .awake);
        if (try out.push(value) == .done) return;
    }
}

test "the first failure in a system is returned" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const failing = program(range(u32, 0, 10), pipe(.{ map(failAtTwo), subscribe(toLeft) }));
    const slow = program(fromProducer(u32, patiently), pipe(.{subscribe(toRight)}));
    const result = system(.{ failing, slow }).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right } });
    try std.testing.expectError(error.Two, result);
    try left.expect(&.{ 0, 1 });
}

fn has(comptime names: []const [:0]const u8, comptime wanted: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, wanted)) return true;
    return false;
}

test "run has a precise error set" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const queued = program(range(u32, 0, 2), pipe(.{ queue(2), map(failAtTwo), subscribe(toLeft) }));
    const plain = program(range(u32, 0, 2), pipe(.{subscribe(toRight)}));
    const deps = .{ io, Left{ .seen = &left }, Right{ .seen = &right } };

    const Queued = @typeInfo(@TypeOf(queued.run(deps))).error_union.error_set;
    const queued_names = comptime @typeInfo(Queued).error_set.error_names.?;
    try std.testing.expectEqual(@as(usize, 3), queued_names.len);
    try std.testing.expect(comptime has(queued_names, "Two") and has(queued_names, "Canceled") and has(queued_names, "ConcurrencyUnavailable"));

    const Plain = @typeInfo(@TypeOf(plain.run(deps))).error_union.error_set;
    try std.testing.expectEqual(@as(usize, 0), comptime @typeInfo(Plain).error_set.error_names.?.len);

    const Both = @typeInfo(@TypeOf(system(.{ queued, plain }).run(deps))).error_union.error_set;
    try std.testing.expectEqual(@as(usize, 3), comptime @typeInfo(Both).error_set.error_names.?.len);
}

// --- supervision ------------------------------------------------------------
//
// Nothing here measures time. A party that should be interrupted waits far
// longer than a test should take and records whether it woke by itself.

const Idle = struct {
    /// Producers that have begun to wait.
    waiting: std.atomic.Value(usize) = .init(0),
    woke_by_itself: std.atomic.Value(bool) = .init(false),
};

fn idleThenPush(clock: std.Io, idle: *Idle, out: anytype) !void {
    _ = idle.waiting.fetchAdd(1, .seq_cst);
    try clock.sleep(.fromSeconds(5), .awake);
    idle.woke_by_itself.store(true, .seq_cst);
    _ = try out.push(@as(u32, 2));
}

fn idleProgram() @TypeOf(program(fromProducer(u32, idleThenPush), pipe(.{subscribe(toRight)}))) {
    return program(fromProducer(u32, idleThenPush), pipe(.{subscribe(toRight)}));
}

test "merge cancels a source that is not pushing once the pipe is done" {
    var seen: Numbers = .{};
    var idle: Idle = .{};
    const first = merge(.{ fromValue(@as(u32, 7)), fromProducer(u32, idleThenPush) });
    try program(first, pipe(.{ take(1), subscribe(record) })).run(.{ io, &seen, &idle });
    const second = merge(.{ fromProducer(u32, idleThenPush), fromValue(@as(u32, 8)) });
    try program(second, pipe(.{ take(1), subscribe(record) })).run(.{ io, &seen, &idle });
    try seen.expect(&.{ 7, 8 });
    try std.testing.expect(!idle.woke_by_itself.load(.seq_cst));
}

test "merge cancels a source that is not pushing once another source's push fails" {
    var seen: Numbers = .{};
    var idle: Idle = .{};
    const sources = merge(.{ fromValue(@as(u32, 2)), fromProducer(u32, idleThenPush) });
    const result = program(sources, pipe(.{ map(failAtTwo), subscribe(record) })).run(.{ io, &seen, &idle });
    try std.testing.expectError(error.Two, result);
    try std.testing.expect(!idle.woke_by_itself.load(.seq_cst));
}

test "a system returns a failure while another program is waiting" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var idle: Idle = .{};
    const failing = program(fromValue(@as(u32, 2)), pipe(.{ map(failAtTwo), subscribe(toLeft) }));
    const deps = .{ io, &idle, Left{ .seen = &left }, Right{ .seen = &right } };
    try std.testing.expectError(error.Two, system(.{ failing, idleProgram() }).run(deps));
    try std.testing.expectError(error.Two, system(.{ idleProgram(), failing }).run(deps));
    try std.testing.expectError(error.Two, system(.{ idleProgram(), failing, idleProgram() }).run(deps));
    try std.testing.expect(!idle.woke_by_itself.load(.seq_cst));
}

test "members never run on the supervising task, however busy the async pool is" {
    // With no async capacity, `Io.async` would run a member on the caller,
    // which then could not see the other one fail.
    var backend: std.Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
    defer backend.deinit();
    var left: Numbers = .{};
    var right: Numbers = .{};
    var idle: Idle = .{};
    const failing = program(fromValue(@as(u32, 2)), pipe(.{ map(failAtTwo), subscribe(toLeft) }));
    const deps = .{ backend.io(), &idle, Left{ .seen = &left }, Right{ .seen = &right } };
    try std.testing.expectError(error.Two, system(.{ idleProgram(), failing }).run(deps));

    var seen: Numbers = .{};
    const sources = merge(.{ fromProducer(u32, idleThenPush), fromValue(@as(u32, 7)) });
    try program(sources, pipe(.{ take(1), subscribe(record) })).run(.{ backend.io(), &seen, &idle });
    try seen.expect(&.{7});
    try std.testing.expect(!idle.woke_by_itself.load(.seq_cst));
}

test "without concurrency, a system and a merge fail before anything runs" {
    var backend: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer backend.deinit();
    var left: Numbers = .{};
    var right: Numbers = .{};
    const a = program(fromValue(@as(u32, 1)), pipe(.{subscribe(toLeft)}));
    const b = program(fromValue(@as(u32, 2)), pipe(.{subscribe(toRight)}));
    const together = system(.{ a, b }).run(.{ backend.io(), Left{ .seen = &left }, Right{ .seen = &right } });
    try std.testing.expectError(error.ConcurrencyUnavailable, together);
    try left.expect(&.{});
    try right.expect(&.{});

    var seen: Numbers = .{};
    const merged = program(merge(.{ fromValue(@as(u32, 1)), fromValue(@as(u32, 2)) }), pipe(.{subscribe(record)}));
    try std.testing.expectError(error.ConcurrencyUnavailable, merged.run(.{ backend.io(), &seen }));
    try seen.expect(&.{});
}

test "running out of concurrency part-way cancels the members already started" {
    var backend: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(1) });
    defer backend.deinit();
    var right: Numbers = .{};
    var idle: Idle = .{};
    const result = system(.{ idleProgram(), idleProgram() }).run(.{ backend.io(), &idle, Right{ .seen = &right } });
    try std.testing.expectError(error.ConcurrencyUnavailable, result);
    try std.testing.expect(!idle.woke_by_itself.load(.seq_cst));
}

test "cancelling the caller cancels every member" {
    var right: Numbers = .{};
    var idle: Idle = .{};
    const both = system(.{ idleProgram(), idleProgram() });
    const Both = @TypeOf(both);
    const Deps = struct { std.Io, *Idle, Right };
    const Caller = struct {
        fn run(members: *const Both, deps: Deps) ?anyerror {
            members.run(deps) catch |err| return err;
            return null;
        }
    };
    var caller = try io.concurrent(Caller.run, .{ &both, Deps{ io, &idle, Right{ .seen = &right } } });
    // Both members are waiting, so the caller is past starting them.
    while (idle.waiting.load(.seq_cst) < 2) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), caller.cancel(io));
    try std.testing.expect(!idle.woke_by_itself.load(.seq_cst));
}
