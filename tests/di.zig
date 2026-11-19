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

test "program bindings are defaults: a value given to run replaces one, the others stay" {
    var seen: Numbers = .{};
    const app = program(range(u32, 1, 3), pipe(.{ map(scaleAndShift), forEach(record) }))
        .provide(.{Scale{ .by = 2 }})
        .provide(.{Offset{ .by = 1 }});
    try app.run(.{&seen});
    try seen.expect(&.{ 3, 5 });

    seen = .{};
    try app.run(.{ Scale{ .by = 100 }, &seen });
    try seen.expect(&.{ 101, 201 });
}

test "provide and run are one set of bindings, wherever each is written" {
    const work = pipe(.{ map(scaleAndShift), forEach(record) });
    const source = range(u32, 1, 3);
    const scale_by: Scale = .{ .by = 10 };
    const offset_by: Offset = .{ .by = 1 };
    var logs: [4]Numbers = @splat(.{});
    try program(source, work).run(.{ scale_by, offset_by, &logs[0] });
    try program(source, work).provide(.{ scale_by, offset_by }).run(.{&logs[1]});
    try program(source, work).provide(.{offset_by}).run(.{ &logs[2], scale_by });
    try program(source, work).provide(.{ &logs[3], offset_by, scale_by }).run(.{});
    for (&logs) |*seen| try seen.expect(&.{ 11, 21 });
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

test "resources are acquired once what they need is there, and released in reverse" {
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

test "a resource may be written before what it needs, in provide or in run" {
    const work = pipe(.{ map(useSession), forEach(record) });
    const source = range(u32, 0, 2);
    const connection = resource(connect, disconnect);
    const session = resource(openSession, closeSession);
    var journals: [4]Journal = @splat(.{});
    var seen: [4]Numbers = @splat(.{});
    // The session needs the connection, and both need the journal.
    try program(source, work).provide(.{ session, connection }).run(.{ &journals[0], &seen[0] });
    try program(source, work).provide(.{session}).run(.{ &seen[1], connection, &journals[1] });
    try program(source, work).provide(.{connection}).run(.{ session, &journals[2], &seen[2] });
    try program(source, work).run(.{ session, &seen[3], connection, &journals[3] });
    for (&journals) |*journal| try journal.expect("CS..sc");
    for (&seen) |*log| try log.expect(&.{ 8, 9 });
}

const Cache = struct { id: u32 };
const Report = struct { id: u32 };

fn warm(journal: *Journal) Cache {
    journal.add('W');
    return .{ .id = 1 };
}
fn drop(journal: *Journal, _: Cache) void {
    journal.add('w');
}
fn openReport(journal: *Journal, session: Session, cache: Cache) Report {
    journal.add('R');
    return .{ .id = session.id + cache.id };
}
fn closeReport(journal: *Journal, _: Report) void {
    journal.add('r');
}
fn useReport(report: Report, value: u32) u32 {
    return value + report.id;
}

test "independent resources are acquired in written order; one that needs others comes after them" {
    const work = pipe(.{ map(useReport), forEach(record) });
    const source = range(u32, 0, 1);
    const connection = resource(connect, disconnect);
    const session = resource(openSession, closeSession);
    const cache = resource(warm, drop);
    const report = resource(openReport, closeReport);

    // The cache and the connection need only the journal: written order decides.
    var journal: Journal = .{};
    var seen: Numbers = .{};
    try program(source, work).run(.{ report, cache, session, connection, &journal, &seen });
    try journal.expect("WCSRrscw");
    try seen.expect(&.{9});

    journal = .{};
    try program(source, work).run(.{ report, session, connection, cache, &journal, &seen });
    try journal.expect("CSWRrwsc");

    // Defaults are written before what `run` is given.
    journal = .{};
    try program(source, work).provide(.{ report, connection }).run(.{ cache, session, &journal, &seen });
    try journal.expect("CWSRrswc");
}

fn useConnection(connection: Connection, value: u32) u32 {
    return value + connection.id;
}

test "a default resource that run replaces is not acquired" {
    var journal: Journal = .{};
    var seen: Numbers = .{};
    const direct = program(range(u32, 0, 2), pipe(.{ map(useConnection), forEach(record) }))
        .provide(.{resource(connect, disconnect)});
    try direct.run(.{ Connection{ .id = 40 }, &journal, &seen });
    try seen.expect(&.{ 40, 41 });
    try journal.expect("");

    // What needs the replaced binding is built from the replacement.
    seen = .{};
    const through = program(range(u32, 0, 2), pipe(.{ map(useSession), forEach(record) }))
        .provide(.{ resource(openSession, closeSession), resource(connect, disconnect) });
    try through.run(.{ Connection{ .id = 40 }, &journal, &seen });
    try seen.expect(&.{ 41, 42 });
    try journal.expect("S..s");
}

fn borrow(journal: *Journal) Connection {
    journal.add('B');
    return .{ .id = 20 };
}

test "a resource given to run replaces a default of the same type" {
    var journal: Journal = .{};
    var seen: Numbers = .{};
    const app = program(range(u32, 0, 2), pipe(.{ map(useConnection), forEach(record) }))
        .provide(.{resource(connect, disconnect)});
    try app.run(.{ &seen, resource(borrow, null), &journal });
    try seen.expect(&.{ 20, 21 });
    try journal.expect("B");
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
