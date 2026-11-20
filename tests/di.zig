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
const rescue = zrx.rescue;
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
    try support.run(program(range(u32, 1, 4), work), .{ Offset{ .by = 1 }, &seen, Scale{ .by = 10 } });
    try seen.expect(&.{ 11, 21, 31 });
}

test "a dependency may be shared by several handlers" {
    var seen: Numbers = .{};
    const work = pipe(.{ map(scale), map(scale), forEach(record) });
    try support.run(program(range(u32, 1, 3), work), .{ Scale{ .by = 3 }, &seen });
    try seen.expect(&.{ 9, 18 });
}

test "program bindings are visible to the source and pipe" {
    var seen: Numbers = .{};
    const app = program(zrx.fromProducer(u32, produce), pipe(.{ map(scale), forEach(record) }))
        .provide(.{Scale{ .by = 5 }});
    try support.run(app, .{&seen});
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
    try support.run(app, .{&seen});
    try seen.expect(&.{ 3, 5 });

    seen = .{};
    try support.run(app, .{ Scale{ .by = 100 }, &seen });
    try seen.expect(&.{ 101, 201 });
}

test "provide and run are one set of bindings, wherever each is written" {
    const work = pipe(.{ map(scaleAndShift), forEach(record) });
    const source = range(u32, 1, 3);
    const scale_by: Scale = .{ .by = 10 };
    const offset_by: Offset = .{ .by = 1 };
    var logs: [4]Numbers = @splat(.{});
    try support.run(program(source, work), .{ scale_by, offset_by, &logs[0] });
    try support.run(program(source, work).provide(.{ scale_by, offset_by }), .{&logs[1]});
    try support.run(program(source, work).provide(.{offset_by}), .{ &logs[2], scale_by });
    try support.run(program(source, work).provide(.{ &logs[3], offset_by, scale_by }), .{});
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
    try support.run(program(range(u32, 1, 3), work).provide(.{Scale{ .by = 10 }}), .{ Left{ .seen = &left }, Right{ .seen = &right } });
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
    try support.run(program(range(u32, 0, 2), work).provide(.{ resource(connect, disconnect), resource(openSession, closeSession) }), .{ &journal, &seen });
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
    try support.run(program(source, work).provide(.{ session, connection }), .{ &journals[0], &seen[0] });
    try support.run(program(source, work).provide(.{session}), .{ &seen[1], connection, &journals[1] });
    try support.run(program(source, work).provide(.{connection}), .{ session, &journals[2], &seen[2] });
    try support.run(program(source, work), .{ session, &seen[3], connection, &journals[3] });
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
    try support.run(program(source, work), .{ report, cache, session, connection, &journal, &seen });
    try journal.expect("WCSRrscw");
    try seen.expect(&.{9});

    journal = .{};
    try support.run(program(source, work), .{ report, session, connection, cache, &journal, &seen });
    try journal.expect("CSWRrwsc");

    // Defaults are written before what `run` is given.
    journal = .{};
    try support.run(program(source, work).provide(.{ report, connection }), .{ cache, session, &journal, &seen });
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
    try support.run(direct, .{ Connection{ .id = 40 }, &journal, &seen });
    try seen.expect(&.{ 40, 41 });
    try journal.expect("");

    // What needs the replaced binding is built from the replacement.
    seen = .{};
    const through = program(range(u32, 0, 2), pipe(.{ map(useSession), forEach(record) }))
        .provide(.{ resource(openSession, closeSession), resource(connect, disconnect) });
    try support.run(through, .{ Connection{ .id = 40 }, &journal, &seen });
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
    try support.run(app, .{ &seen, resource(borrow, null), &journal });
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
    try std.testing.expectError(error.Boom, support.run(program(range(u32, 0, 3), work).provide(.{resource(connect, disconnect)}), .{ &journal, &seen }));
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
    try std.testing.expectError(error.Refused, support.run(program(range(u32, 0, 3), work).provide(.{ resource(connect, disconnect), resource(refuse, closeSession) }), .{ &journal, &seen }));
    try journal.expect("CXc");
    try seen.expect(&.{});
}

fn derive(factor: Scale) Offset {
    return .{ .by = factor.by * 100 };
}

test "a resource without release is a dependency computed from others" {
    var seen: Numbers = .{};
    const work = pipe(.{ map(shift), forEach(record) });
    try support.run(program(range(u32, 1, 3), work).provide(.{resource(derive, null)}), .{ Scale{ .by = 2 }, &seen });
    try seen.expect(&.{ 201, 202 });
}

// --- rescue ---------------------------------------------------------------

/// What a rescue was called with, and how often.
const Failure = struct { err: ?anyerror = null, calls: u32 = 0 };

fn noteFailure(journal: *Journal, failure: *Failure, err: anyerror) void {
    journal.add('!');
    failure.err = err;
    failure.calls += 1;
}

test "a rescue is called once with the failure of the run" {
    var journal: Journal = .{};
    var seen: Numbers = .{};
    var failure: Failure = .{};
    const work = pipe(.{ map(failing), forEach(record) });
    program(range(u32, 0, 3), work).run(.{ &journal, &seen, &failure, rescue(noteFailure) });
    try std.testing.expectEqual(Failure{ .err = error.Boom, .calls = 1 }, failure);
    try seen.expect(&.{0});
}

test "a rescue is not called for a run that succeeds, and what it was given is not acquired" {
    var journal: Journal = .{};
    var seen: Numbers = .{};
    var failure: Failure = .{};
    const guard = rescue(noteWithSession).provide(.{ resource(connect, disconnect), resource(openSession, closeSession) });
    program(range(u32, 2, 4), pipe(.{ map(failing), forEach(record) })).run(.{ &journal, &seen, &failure, guard });
    try std.testing.expectEqual(Failure{}, failure);
    try seen.expect(&.{ 2, 3 });
    try journal.expect("");
}

fn noteWithSession(journal: *Journal, _: Session, failure: *Failure, err: anyerror) void {
    noteFailure(journal, failure, err);
}

test "a rescue is called once everything the run acquired is released, with bindings of its own" {
    var journal: Journal = .{};
    var seen: Numbers = .{};
    var failure: Failure = .{};
    // The run's connection and session, one item, both released; then the
    // rescue's own pair, the rescue, and those released.
    const guard = rescue(noteWithSession).provide(.{ resource(connect, disconnect), resource(openSession, closeSession) });
    const app = program(range(u32, 0, 3), pipe(.{ map(failing), map(useSession), forEach(record) }))
        .provide(.{ resource(connect, disconnect), resource(openSession, closeSession) });
    app.run(.{ &journal, &seen, &failure, guard });
    try journal.expect("CS.scCS!sc");
    try std.testing.expectEqual(Failure{ .err = error.Boom, .calls = 1 }, failure);
}

/// Every order three bindings can be written in.
fn orders(comptime a: anytype, comptime b: anytype, comptime c: anytype) @TypeOf(.{
    .{ a, b, c }, .{ a, c, b }, .{ b, a, c }, .{ b, c, a }, .{ c, a, b }, .{ c, b, a },
}) {
    return .{ .{ a, b, c }, .{ a, c, b }, .{ b, a, c }, .{ b, c, a }, .{ c, a, b }, .{ c, b, a } };
}

test "a rescue takes the failure of any resource, wherever it and the resources are written" {
    const connection = resource(connect, disconnect);
    const refusing = resource(refuse, closeSession);
    const guard = rescue(noteFailure);
    const work = pipe(.{ map(useSession), forEach(record) });
    // In `run`, in every order.
    inline for (orders(connection, refusing, guard)) |bindings| {
        var journal: Journal = .{};
        var seen: Numbers = .{};
        var failure: Failure = .{};
        program(range(u32, 0, 3), work).run(.{ &journal, &seen, &failure } ++ bindings);
        try journal.expect("CXc!");
        try std.testing.expectEqual(Failure{ .err = error.Refused, .calls = 1 }, failure);
    }
    // Split between `provide` and `run`, either way round.
    inline for (.{
        .{ .{ connection, refusing }, .{guard} },
        .{ .{guard}, .{ refusing, connection } },
        .{ .{ refusing, guard }, .{connection} },
        .{ .{connection}, .{ guard, refusing } },
    }) |split| {
        var journal: Journal = .{};
        var seen: Numbers = .{};
        var failure: Failure = .{};
        program(range(u32, 0, 3), work).provide(split[0]).run(.{ &journal, &seen, &failure } ++ split[1]);
        try journal.expect("CXc!");
        try std.testing.expectEqual(Failure{ .err = error.Refused, .calls = 1 }, failure);
    }
}

fn noteBoom(failure: *Failure, err: error{Boom}) void {
    failure.err = err;
    failure.calls += 1;
}

test "a rescue may name the errors it takes, when they are all the run can fail with" {
    var seen: Numbers = .{};
    var failure: Failure = .{};
    program(range(u32, 0, 3), pipe(.{ map(failing), forEach(record) })).provide(.{rescue(noteBoom)}).run(.{ &seen, &failure });
    try std.testing.expectEqual(Failure{ .err = error.Boom, .calls = 1 }, failure);
}

/// Names every error it can be given: this compiles only if those are
/// exactly the errors of the run. A cancellation is one of them.
fn noteExactly(failure: *Failure, err: anytype) void {
    failure.err = switch (err) {
        error.Boom => error.Boom,
        error.Refused => error.Refused,
        error.Canceled => error.Canceled,
    };
    failure.calls += 1;
}
fn noteAny(failure: *Failure, err: anyerror) void {
    failure.err = err;
    failure.calls += 1;
}

fn interrupted(value: u32) error{ Boom, Canceled }!u32 {
    if (value == 1) return error.Canceled;
    if (value == 2) return error.Boom;
    return value;
}
fn sessionOrRefuse(journal: *Journal, connection: Connection) error{Refused}!Session {
    return openSession(journal, connection);
}

test "a rescue is given exactly the errors of the run, and a cancellation like any of them" {
    inline for (.{ noteExactly, noteAny }) |handler| {
        var journal: Journal = .{};
        var seen: Numbers = .{};
        var failure: Failure = .{};
        const app = program(range(u32, 0, 3), pipe(.{ map(interrupted), forEach(record) }));
        app.run(.{ &journal, &seen, &failure, rescue(handler), resource(connect, disconnect), resource(sessionOrRefuse, closeSession) });
        try std.testing.expectEqual(Failure{ .err = error.Canceled, .calls = 1 }, failure);
        try seen.expect(&.{0});
    }
}

fn noteDefault(journal: *Journal, _: anyerror) void {
    journal.add('d');
}

test "a rescue given to run replaces the one a program provides" {
    var journal: Journal = .{};
    var seen: Numbers = .{};
    var failure: Failure = .{};
    const app = program(range(u32, 0, 3), pipe(.{ map(failing), forEach(record) })).provide(.{rescue(noteDefault)});
    app.run(.{ &journal, &seen });
    try journal.expect("d");
    journal = .{};
    app.run(.{ &journal, &seen, &failure, rescue(noteFailure) });
    try journal.expect("!");
}

const Notes = struct { text: []const u8 };
fn noteText(journal: *Journal, notes: Notes, _: anyerror) void {
    for (notes.text) |byte| journal.add(byte);
}

test "a value given to run replaces what a rescue was given for itself" {
    var journal: Journal = .{};
    var seen: Numbers = .{};
    const app = program(range(u32, 0, 3), pipe(.{ map(failing), forEach(record) }))
        .provide(.{rescue(noteText).provide(.{Notes{ .text = "own" }})});
    app.run(.{ &journal, &seen });
    try journal.expect("own");
    // A test hands the rescue a value in place of what it would acquire.
    journal = .{};
    app.run(.{ &journal, &seen, Notes{ .text = "given" } });
    try journal.expect("given");
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
    try support.run(program(range(u32, 1, 3), pipe(.{ map(widen), map(narrow), forEach(record) })), .{&seen});
    try seen.expect(&.{ 1, 2 });
}

const Counter = struct { total: u32 = 0 };
fn bump(counter: *Counter, value: u32) void {
    counter.total += value;
}

test "a pointer dependency is shared, not copied" {
    var counter: Counter = .{};
    try support.run(program(range(u32, 1, 4), pipe(.{ tap(bump), forEach(bump) })), .{&counter});
    try std.testing.expectEqual(@as(u32, 12), counter.total);
}
