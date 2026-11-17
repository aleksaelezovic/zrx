//! Dependency injection: by type, at `run` and on programs.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");

const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const filter = zrx.filter;
const tap = zrx.tap;
const resource = zrx.resource;
const branch = zrx.branch;
const forEach = zrx.forEach;

const Numbers = support.Recorder(u32);
const record = support.record(u32);

const Scale = struct { by: u32 };
const Offset = struct { by: u32 };

fn scale(factor: Scale, value: u32) u32 {
    return value * factor.by;
}
fn shift(offset: Offset, value: u32) u32 {
    return value + offset.by;
}
fn scaleAndShift(factor: Scale, offset: Offset, value: u32) u32 {
    return value * factor.by + offset.by;
}

test "handlers receive the dependencies they name, whatever the order at run" {
    var seen: Numbers = .{};
    const work = pipe(.{ map(scaleAndShift), forEach(record) });
    try program(range(u32, 1, 4), work).run(.{ Offset{ .by = 1 }, &seen, Scale{ .by = 10 } });
    try seen.expect(&.{ 11, 21, 31 });
}

test "a dependency may be shared by several handlers" {
    var seen: Numbers = .{};
    const work = pipe(.{ map(scale), map(scale), forEach(record) });
    try program(range(u32, 1, 3), work).run(.{ Scale{ .by = 3 }, &seen });
    try seen.expect(&.{ 9, 18 });
}

test "program bindings are visible to the source and pipe" {
    var seen: Numbers = .{};
    const app = program(zrx.fromProducer(u32, produce), pipe(.{ map(scale), forEach(record) }))
        .provide(.{Scale{ .by = 5 }});
    try app.run(.{&seen});
    try seen.expect(&.{25});
}

fn produce(factor: Scale, out: anytype) !void {
    _ = try out.push(factor.by);
}

test "program bindings shadow caller values and can be extended" {
    var seen: Numbers = .{};
    const app = program(range(u32, 1, 3), pipe(.{ map(scaleAndShift), forEach(record) }))
        .provide(.{Scale{ .by = 2 }})
        .provide(.{Offset{ .by = 1 }});
    try app.run(.{ Scale{ .by = 100 }, &seen });
    try seen.expect(&.{ 3, 5 });
}

const Left = struct { seen: *Numbers };
const Right = struct { seen: *Numbers };
fn toLeft(sink: Left, value: u32) void {
    sink.seen.add(value);
}
fn toRight(sink: Right, value: u32) void {
    sink.seen.add(value);
}

test "program bindings are visible to both branches" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{ map(scale), forEach(toLeft) }),
        pipe(.{ map(scale), forEach(toRight) }),
    })});
    try program(range(u32, 1, 3), work).provide(.{Scale{ .by = 10 }}).run(.{ Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 10, 20 });
    try right.expect(&.{ 10, 20 });
}

// --- resources ------------------------------------------------------------

const Journal = support.Recorder(u8);
const Connection = struct { id: u32 };
const Session = struct { id: u32 };

fn connect(journal: *Journal) Connection {
    journal.add('C');
    return .{ .id = 7 };
}
fn disconnect(journal: *Journal, _: Connection) void {
    journal.add('c');
}
fn openSession(journal: *Journal, connection: Connection) Session {
    journal.add('S');
    return .{ .id = connection.id + 1 };
}
fn closeSession(journal: *Journal, _: Session) void {
    journal.add('s');
}
fn useSession(journal: *Journal, session: Session, value: u32) u32 {
    journal.add('.');
    return value + session.id;
}

test "resources are acquired in order, provided downstream, and released in reverse" {
    var journal: Journal = .{};
    var seen: Numbers = .{};
    const work = pipe(.{
        map(useSession),
        forEach(record),
    });
    try program(range(u32, 0, 2), work).provide(.{ resource(connect, disconnect), resource(openSession, closeSession) }).run(.{ &journal, &seen });
    try seen.expect(&.{ 8, 9 });
    try journal.expect("CS..sc");
}

fn failing(value: u32) error{Boom}!u32 {
    if (value == 1) return error.Boom;
    return value;
}

test "resources are released when the run fails" {
    var journal: Journal = .{};
    var seen: Numbers = .{};
    const work = pipe(.{ map(failing), forEach(record) });
    try std.testing.expectError(error.Boom, program(range(u32, 0, 3), work).provide(.{resource(connect, disconnect)}).run(.{ &journal, &seen }));
    try journal.expect("Cc");
}

fn refuse(journal: *Journal, _: Connection) error{Refused}!Session {
    journal.add('X');
    return error.Refused;
}

test "a failed acquire releases what was acquired before it and runs nothing" {
    var journal: Journal = .{};
    var seen: Numbers = .{};
    const work = pipe(.{ map(useSession), forEach(record) });
    try std.testing.expectError(error.Refused, program(range(u32, 0, 3), work).provide(.{ resource(connect, disconnect), resource(refuse, closeSession) }).run(.{ &journal, &seen }));
    try journal.expect("CXc");
    try seen.expect(&.{});
}

fn derive(factor: Scale) Offset {
    return .{ .by = factor.by * 100 };
}

test "a resource without release is a dependency computed from others" {
    var seen: Numbers = .{};
    const work = pipe(.{ map(shift), forEach(record) });
    try program(range(u32, 1, 3), work).provide(.{resource(derive, null)}).run(.{ Scale{ .by = 2 }, &seen });
    try seen.expect(&.{ 201, 202 });
}

// --- generic handlers -----------------------------------------------------

fn widen(value: anytype) u64 {
    return value;
}
fn narrow(value: u64) u32 {
    return @intCast(value);
}

test "the data parameter of a handler may be generic" {
    var seen: Numbers = .{};
    try program(range(u32, 1, 3), pipe(.{ map(widen), map(narrow), forEach(record) })).run(.{&seen});
    try seen.expect(&.{ 1, 2 });
}

const Counter = struct { total: u32 = 0 };
fn bump(counter: *Counter, value: u32) void {
    counter.total += value;
}

test "a pointer dependency is shared, not copied" {
    var counter: Counter = .{};
    try program(range(u32, 1, 4), pipe(.{ tap(bump), forEach(bump) })).run(.{&counter});
    try std.testing.expectEqual(@as(u32, 12), counter.total);
}
