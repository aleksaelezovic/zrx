//! Sources and programs.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const fromValue = zrx.fromValue;
const range = zrx.range;
const fromIterator = zrx.fromIterator;
const fromProducer = zrx.fromProducer;
const map = zrx.map;
const fold = zrx.fold;
const take = zrx.take;
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

// --- errors -----------------------------------------------------------------

fn failAtTwo(value: u32) error{Two}!u32 {
    if (value == 2) return error.Two;
    return value;
}

test "run has a precise error set" {
    var seen: Numbers = .{};
    const failing = program(range(u32, 0, 5), pipe(.{ map(failAtTwo), subscribe(record) }));
    const plain = program(range(u32, 0, 2), pipe(.{subscribe(record)}));

    const Failing = @typeInfo(@TypeOf(failing.run(.{&seen}))).error_union.error_set;
    const names = comptime @typeInfo(Failing).error_set.error_names.?;
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("Two", names[0]);

    const Plain = @typeInfo(@TypeOf(plain.run(.{&seen}))).error_union.error_set;
    try std.testing.expectEqual(@as(usize, 0), comptime @typeInfo(Plain).error_set.error_names.?.len);

    try std.testing.expectError(error.Two, failing.run(.{&seen}));
    try seen.expect(&.{ 0, 1 });
}
