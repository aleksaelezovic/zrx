//! The public contracts for operators, sources and handlers written outside
//! the library. The operator below is the one shown in docs/guide.md.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");

const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const filter = zrx.filter;
const take = zrx.take;
const subscribe = zrx.subscribe;

const Numbers = support.Recorder(u32);
const record = support.record(u32);

// --- an operator ------------------------------------------------------------

pub fn counted() Counted {
    return .{};
}

const Counted = struct {
    pub const zrx_operator = {};
    pub const name = "counted";

    pub fn Out(comptime Env: type, comptime In: type) type {
        if (!zrx.di.has(Env, *usize)) @compileError("counted: needs a `*usize` dependency");
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            count: *usize,

            pub fn init(self: *@This(), _: *const Counted, env: Env) !void {
                self.count = zrx.di.get(env, *usize);
            }

            pub fn push(self: *@This(), item: In, down: anytype) !zrx.Flow {
                self.count.* += 1;
                return down.push(item);
            }
        };
    }
};

test "a custom operator composes with the built-in ones" {
    var seen: Numbers = .{};
    var count: usize = 0;
    try program(range(u32, 0, 100), pipe(.{ counted(), take(3), subscribe(record) })).run(.{ &seen, &count });
    try seen.expect(&.{ 0, 1, 2 });
    try std.testing.expectEqual(@as(usize, 3), count);
}

// --- an operator with every optional hook --------------------------------------

const Journal = support.Recorder(u8);

/// Emits each item twice and one extra `tail` item when the stream ends.
fn echoed(tail: u32) Echoed {
    return .{ .tail = tail };
}

const Echoed = struct {
    tail: u32,

    pub const zrx_operator = {};
    pub const name = "echoed";

    pub fn Out(comptime _: type, comptime In: type) type {
        if (In != u32) @compileError("echoed: items must be u32");
        return u32;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            journal: *Journal,
            tail: u32,

            pub fn init(self: *@This(), op: *const Echoed, env: Env) !void {
                self.* = .{ .journal = zrx.di.get(env, *Journal), .tail = op.tail };
                self.journal.add('i');
            }

            pub fn start(self: *@This(), _: anytype) !zrx.Flow {
                self.journal.add('s');
                return .more;
            }

            pub fn push(self: *@This(), item: In, down: anytype) !zrx.Flow {
                self.journal.add('p');
                if (try down.push(item) == .done) return .done;
                return down.push(item);
            }

            pub fn finish(self: *@This(), down: anytype) !void {
                self.journal.add('f');
                _ = try down.push(self.tail);
            }

            pub fn flush(self: *@This()) !void {
                self.journal.add('F');
            }

            pub fn stop(self: *@This()) void {
                self.journal.add('t');
            }

            pub fn deinit(self: *@This()) void {
                self.journal.add('d');
            }
        };
    }
};

test "stage hooks run in the documented order" {
    var seen: Numbers = .{};
    var journal: Journal = .{};
    try program(range(u32, 1, 3), pipe(.{ echoed(9), subscribe(record) })).run(.{ &seen, &journal });
    try seen.expect(&.{ 1, 1, 2, 2, 9 });
    try journal.expect("isppfFtd");
}

fn failAtTwo(value: u32) error{Two}!u32 {
    if (value == 2) return error.Two;
    return value;
}

test "a failed run skips finish and flush but not stop and deinit" {
    var seen: Numbers = .{};
    var journal: Journal = .{};
    const result = program(range(u32, 1, 3), pipe(.{ echoed(9), map(failAtTwo), subscribe(record) })).run(.{ &seen, &journal });
    try std.testing.expectError(error.Two, result);
    try journal.expect("ispptd");
}

// --- a source -----------------------------------------------------------------

/// Powers of two below `limit`.
const Powers = struct {
    limit: u32,

    pub const zrx_source = {};
    pub const Item = u32;

    pub fn run(self: *const Powers, _: anytype, down: anytype) !void {
        var value: u32 = 1;
        while (value < self.limit) : (value *= 2) {
            if (try down.push(value) == .done) return;
        }
    }
};

test "a custom source" {
    var seen: Numbers = .{};
    try program(Powers{ .limit = 40 }, pipe(.{subscribe(record)})).run(.{&seen});
    try program(Powers{ .limit = 1 << 30 }, pipe(.{ take(2), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 1, 2, 4, 8, 16, 32, 1, 2 });
}

// --- a composite handler ---------------------------------------------------------

/// A predicate that is true when `predicate` is true for the item plus one.
fn next(comptime predicate: anytype) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            return zrx.di.requires("next", predicate, arity);
        }

        pub fn call(env: anytype, args: anytype) bool {
            return zrx.di.invoke(predicate, env, .{args[0] + 1});
        }
    };
}

const Limit = struct { max: u32 };
fn withinLimit(limit: Limit, value: u32) bool {
    return value <= limit.max;
}

test "a custom composite handler forwards dependencies" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 10), pipe(.{ filter(next(withinLimit)), subscribe(record) })).run(.{ &seen, Limit{ .max = 3 } });
    try seen.expect(&.{ 0, 1, 2 });
}

// --- a stage that reports a failure of its own -------------------------------------

/// Trips on a value it does not like, the way a stage with a worker reports
/// that its worker failed. It takes part in the run's supervision, and what it
/// reports is what its `failure` returns.
const Tripwire = struct {
    limit: u32,

    pub const zrx_operator = {};
    pub const name = "tripwire";

    pub fn Out(comptime Env: type, comptime In: type) type {
        if (!zrx.di.has(Env, std.Io)) @compileError("tripwire: needs `std.Io`");
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            io: std.Io,
            limit: u32,
            tripped: bool,
            supervision: zrx.operator.Supervision,

            /// Makes the program supervise this run.
            pub const zrx_boundary = {};

            pub fn init(self: *@This(), op: *const Tripwire, env: Env) !void {
                self.* = .{
                    .io = zrx.di.get(env, std.Io),
                    .limit = op.limit,
                    .tripped = false,
                    .supervision = zrx.di.get(env, zrx.operator.Supervision),
                };
                self.supervision.adopt(self.io);
            }

            pub fn push(self: *@This(), item: In, down: anytype) !zrx.Flow {
                if (item > self.limit) {
                    self.tripped = true;
                    self.supervision.fail(self.io, self);
                    return .done;
                }
                return down.push(item);
            }

            pub fn failure(self: *@This(), _: anytype) error{Tripped}!void {
                if (self.tripped) return error.Tripped;
            }
        };
    }
};

test "a custom stage's reported failure is the run's result, with its own error set" {
    var seen: Numbers = .{};
    const guarded = program(range(u32, 0, 10), pipe(.{ Tripwire{ .limit = 2 }, subscribe(record) }));
    try std.testing.expectError(error.Tripped, guarded.run(.{ std.testing.io, &seen }));
    try seen.expect(&.{ 0, 1, 2 });

    const Result = @TypeOf(guarded.run(.{ std.testing.io, &seen }));
    const names = comptime @typeInfo(@typeInfo(Result).error_union.error_set).error_set.error_names.?;
    comptime var found = false;
    inline for (names) |error_name| {
        if (comptime std.mem.eql(u8, error_name, "Tripped")) found = true;
    }
    try std.testing.expect(found);
}

// --- an operator built on another one -------------------------------------------

fn isOdd(value: u32) bool {
    return value % 2 == 1;
}
fn addUp(sum: u32, value: u32) u32 {
    return sum + value;
}

const sums_by_parity = zrx.route(.{
    zrx.when(isOdd, pipe(.{zrx.fold(@as(u32, 0), addUp)})),
    zrx.otherwise(pipe(.{zrx.fold(@as(u32, 0), addUp)})),
});

/// Ends a pipe by running a route of its own and collecting what it emits.
/// What it gives the route as `down` is its own: anything with a `push`.
fn Collected(comptime by_pointer: bool) type {
    return struct {
        /// Whether the receiver answers `.done` to whatever it gets.
        satisfied_by_one: bool = false,

        const Op = @This();
        const Inner = @TypeOf(sums_by_parity);

        pub const zrx_operator = {};
        pub const name = "collected";

        pub fn Out(comptime Env: type, comptime In: type) type {
            if (Inner.Out(Env, In) != u32) @compileError("collected: items must be u32");
            return zrx.End;
        }

        const ByPointer = struct {
            seen: *Numbers,
            satisfied_by_one: bool,

            pub fn push(self: *ByPointer, item: u32) !zrx.Flow {
                self.seen.add(item);
                return if (self.satisfied_by_one) .done else .more;
            }
        };

        const ByValue = struct {
            seen: *Numbers,
            satisfied_by_one: bool,

            /// Nothing the library should mistake for something of its own.
            pub const isDone = false;

            pub fn push(self: ByValue, item: u32) !zrx.Flow {
                self.seen.add(item);
                return if (self.satisfied_by_one) .done else .more;
            }
        };

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                inner: Inner.Stage(Env, In),
                receiver: if (by_pointer) ByPointer else ByValue,

                const Self = @This();

                fn down(self: *Self) if (by_pointer) *ByPointer else ByValue {
                    return if (by_pointer) &self.receiver else self.receiver;
                }

                pub fn init(self: *Self, op: *const Op, env: Env) !void {
                    self.receiver = .{ .seen = zrx.di.get(env, *Numbers), .satisfied_by_one = op.satisfied_by_one };
                    try self.inner.init(&sums_by_parity, env);
                }

                pub fn start(self: *Self, _: anytype) !zrx.Flow {
                    return self.inner.start(self.down());
                }

                pub fn push(self: *Self, item: In, _: anytype) !zrx.Flow {
                    return self.inner.push(item, self.down());
                }

                pub fn finish(self: *Self, _: anytype) !void {
                    try self.inner.finish(self.down());
                }

                pub fn deinit(self: *Self) void {
                    self.inner.deinit();
                }
            };
        }
    };
}

test "an operator can run a built-in one with a `down` of its own" {
    var by_pointer: Numbers = .{};
    try program(range(u32, 1, 6), pipe(.{Collected(true){}})).run(.{&by_pointer});
    try by_pointer.expect(&.{ 9, 6 });

    var by_value: Numbers = .{};
    try program(range(u32, 1, 6), pipe(.{Collected(false){}})).run(.{&by_value});
    try by_value.expect(&.{ 9, 6 });
}

test "a `down` of its own that answers done is not pushed to again" {
    // Each case of the route emits a final value. The receiver is satisfied
    // by the first; it has only a `push`, so the route has to remember.
    var by_pointer: Numbers = .{};
    try program(range(u32, 1, 6), pipe(.{Collected(true){ .satisfied_by_one = true }})).run(.{&by_pointer});
    try by_pointer.expect(&.{9});

    var by_value: Numbers = .{};
    try program(range(u32, 1, 6), pipe(.{Collected(false){ .satisfied_by_one = true }})).run(.{&by_value});
    try by_value.expect(&.{9});
}

// --- a `down` that can say it is done ---------------------------------------------

/// Emits one value as the run starts.
const Opening = struct {
    pub const zrx_operator = {};
    pub const name = "opening";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            pub fn init(_: *@This(), _: *const Opening, _: Env) !void {}

            pub fn start(_: *@This(), down: anytype) !zrx.Flow {
                return down.push(@as(In, 1));
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }
        };
    }
};

/// Must not be started: its start hook fails.
const Tripping = struct {
    pub const zrx_operator = {};
    pub const name = "tripping";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            pub fn init(_: *@This(), _: *const Tripping, _: Env) !void {}

            pub fn start(_: *@This(), _: anytype) error{StartedAfterDone}!zrx.Flow {
                return error.StartedAfterDone;
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }
        };
    }
};

const opening_then_tripping = zrx.route(.{
    zrx.when(isOdd, pipe(.{Opening{}})),
    zrx.otherwise(pipe(.{Tripping{}})),
});

/// Runs a route with a `down` that says when it is done: from the start, or
/// after it has been asked `open_for` times.
const Shut = struct {
    open_for: usize = 0,

    const Inner = @TypeOf(opening_then_tripping);

    pub const zrx_operator = {};
    pub const name = "shut";

    pub fn Out(comptime Env: type, comptime In: type) type {
        if (Inner.Out(Env, In) != u32) @compileError("shut: items must be u32");
        return zrx.End;
    }

    const Receiver = struct {
        seen: *Numbers,
        asked: *usize,
        open_for: usize,

        pub const zrx_answers_done = {};

        pub fn isDone(self: Receiver) bool {
            defer self.asked.* += 1;
            return self.asked.* >= self.open_for;
        }

        pub fn push(self: Receiver, item: u32) !zrx.Flow {
            self.seen.add(item);
            return .done;
        }
    };

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            inner: Inner.Stage(Env, In),
            receiver: Receiver,
            asked: usize,

            const Self = @This();

            pub fn init(self: *Self, op: *const Shut, env: Env) !void {
                self.asked = 0;
                self.receiver = .{ .seen = zrx.di.get(env, *Numbers), .asked = &self.asked, .open_for = op.open_for };
                try self.inner.init(&opening_then_tripping, env);
            }

            pub fn start(self: *Self, _: anytype) !zrx.Flow {
                return self.inner.start(self.receiver);
            }

            pub fn push(self: *Self, item: In, _: anytype) !zrx.Flow {
                return self.inner.push(item, self.receiver);
            }

            pub fn finish(self: *Self, _: anytype) !void {
                try self.inner.finish(self.receiver);
            }

            pub fn deinit(self: *Self) void {
                self.inner.deinit();
            }
        };
    }
};

test "a `down` that says it is done keeps a route from starting another case" {
    // Nothing was pushed, so the route has no answer to remember: it asks.
    // With the pipe after it done, no case is started, and the second
    // one's start hook would have failed the run.
    var seen: Numbers = .{};
    try program(range(u32, 0, 4), pipe(.{Shut{}})).run(.{&seen});
    try seen.expect(&.{});

    // Here the receiver is done by the time the first case emits. That
    // emission is refused where it is made, which is not the case being
    // done by itself: the route asks again before starting the next one.
    var later: Numbers = .{};
    try program(range(u32, 0, 4), pipe(.{Shut{ .open_for = 1 }})).run(.{&later});
    try later.expect(&.{});
}

// --- done is final, whoever the `down` is ----------------------------------------
//
// One route, run under every kind of `down` and every moment at which what it
// emits into can become done. A receiver says it is done by answering `.done`
// to a push, or by answering `true` when asked. Once it has said so, three
// things must never happen: it is pushed to again, a handler runs for a
// value, a stage is started. And a `down` that can be asked is never pushed
// to while it would have said it is done.

const Watch = struct {
    /// Answers `.done` to this push (1-based); 0 for never.
    done_on_push: usize = 0,
    /// Is done once it has had this many pushes, and says so only when
    /// asked; null for never.
    shut_after: ?usize = null,

    /// It has said it is done.
    told: bool = false,
    pushes: usize = 0,
    seen: Numbers = .{},

    pushed_after: usize = 0,
    pushed_unasked: usize = 0,
    handled_after: usize = 0,
    started_after: usize = 0,
    /// A route was started with a `down` that would have said it is done,
    /// and still answered that it takes items.
    start_missed: usize = 0,

    fn shut(watch: *const Watch) bool {
        if (watch.told) return true;
        const after = watch.shut_after orelse return false;
        return watch.pushes >= after;
    }

    fn receive(watch: *Watch, item: u32, comptime could_have_asked: bool) zrx.Flow {
        if (watch.told) watch.pushed_after += 1;
        if (could_have_asked and watch.shut()) watch.pushed_unasked += 1;
        watch.pushes += 1;
        watch.seen.add(item);
        if (watch.done_on_push != 0 and watch.pushes >= watch.done_on_push) {
            watch.told = true;
            return .done;
        }
        return .more;
    }

    fn ask(watch: *Watch) bool {
        if (!watch.shut()) return false;
        watch.told = true;
        return true;
    }

    fn expectNothingAfterDone(watch: *const Watch) !void {
        try std.testing.expectEqual(@as(usize, 0), watch.pushed_after);
        try std.testing.expectEqual(@as(usize, 0), watch.pushed_unasked);
        try std.testing.expectEqual(@as(usize, 0), watch.handled_after);
        try std.testing.expectEqual(@as(usize, 0), watch.started_after);
        try std.testing.expectEqual(@as(usize, 0), watch.start_missed);
    }
};

fn touch(watch: *Watch, _: u32) void {
    if (watch.told) watch.handled_after += 1;
}

fn isBelowFour(value: u32) bool {
    return value < 4;
}

/// A stage with a start hook, which emits `value` there if it has one, and
/// with a final value `last` if it has one.
const Noting = struct {
    value: ?u32 = null,
    last: ?u32 = null,

    pub const zrx_operator = {};
    pub const name = "noting";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            watch: *Watch,
            value: ?u32,
            last: ?u32,

            pub fn init(self: *@This(), op: *const Noting, env: Env) !void {
                self.* = .{ .watch = zrx.di.get(env, *Watch), .value = op.value, .last = op.last };
            }

            pub fn start(self: *@This(), down: anytype) !zrx.Flow {
                if (self.watch.told) self.watch.started_after += 1;
                return if (self.value) |value| down.push(@as(In, value)) else .more;
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }

            pub fn finish(self: *@This(), down: anytype) !void {
                if (self.last) |last| _ = try down.push(@as(In, last));
            }
        };
    }
};

/// Emits as the run starts, while items flow, and as the stream ends.
const watched = zrx.route(.{
    zrx.when(isOdd, pipe(.{ Noting{ .value = 100 }, zrx.tap(touch) })),
    zrx.when(isBelowFour, pipe(.{ Noting{}, zrx.fold(@as(u32, 0), addUp), zrx.tap(touch) })),
    zrx.otherwise(pipe(.{ Noting{}, zrx.fold(@as(u32, 0), addUp), zrx.tap(touch) })),
});

/// The same, with the case that emits as the run starts last.
const watched_last = zrx.route(.{
    zrx.when(isBelowFour, pipe(.{ Noting{}, zrx.fold(@as(u32, 0), addUp), zrx.tap(touch) })),
    zrx.otherwise(pipe(.{ Noting{ .value = 100 }, zrx.tap(touch) })),
});

const Kind = enum { value, value_answers, pointer, pointer_answers };
const kinds = [_]Kind{ .value, .value_answers, .pointer, .pointer_answers };

const PushOnly = struct {
    watch: *Watch,

    pub fn push(self: PushOnly, item: u32) !zrx.Flow {
        return self.watch.receive(item, false);
    }
};

const Answering = struct {
    watch: *Watch,

    pub const zrx_answers_done = {};

    pub fn isDone(self: Answering) bool {
        return self.watch.ask();
    }

    pub fn push(self: Answering, item: u32) !zrx.Flow {
        return self.watch.receive(item, true);
    }
};

fn Handle(comptime kind: Kind) type {
    return switch (kind) {
        .value => PushOnly,
        .value_answers => Answering,
        .pointer => *PushOnly,
        .pointer_answers => *Answering,
    };
}

/// Ends a pipe by running `inner` with a `down` of the given kind in each hook.
fn Under(comptime inner: anytype, comptime at_start: Kind, comptime per_item: Kind, comptime at_end: Kind) type {
    return struct {
        const Op = @This();
        const Inner = @TypeOf(inner);
        const wrapped: Inner = inner;

        pub const zrx_operator = {};
        pub const name = "under";

        pub fn Out(comptime Env: type, comptime In: type) type {
            if (Inner.Out(Env, In) != u32) @compileError("under: items must be u32");
            return zrx.End;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                inner: Inner.Stage(Env, In),
                watch: *Watch,
                push_only: PushOnly,
                answering: Answering,

                const Self = @This();

                fn handle(self: *Self, comptime kind: Kind) Handle(kind) {
                    return switch (kind) {
                        .value => self.push_only,
                        .value_answers => self.answering,
                        .pointer => &self.push_only,
                        .pointer_answers => &self.answering,
                    };
                }

                pub fn init(self: *Self, _: *const Op, env: Env) !void {
                    const watch = zrx.di.get(env, *Watch);
                    self.watch = watch;
                    self.push_only = .{ .watch = watch };
                    self.answering = .{ .watch = watch };
                    try self.inner.init(&wrapped, env);
                }

                pub fn start(self: *Self, _: anytype) !zrx.Flow {
                    const answer = try self.inner.start(self.handle(at_start));
                    if (comptime answers(at_start)) {
                        if (self.watch.shut() and answer != .done) self.watch.start_missed += 1;
                    }
                    return answer;
                }

                pub fn push(self: *Self, item: In, _: anytype) !zrx.Flow {
                    return self.inner.push(item, self.handle(per_item));
                }

                pub fn finish(self: *Self, _: anytype) !void {
                    try self.inner.finish(self.handle(at_end));
                }

                pub fn deinit(self: *Self) void {
                    self.inner.deinit();
                }
            };
        }
    };
}

/// A case that emits more than one value for an item.
const emits_twice = zrx.route(.{
    zrx.when(isBelowFour, pipe(.{ zrx.batch(2), zrx.flatten(), zrx.tap(touch) })),
    zrx.otherwise(pipe(.{ Noting{ .value = 100 }, zrx.tap(touch) })),
});

/// The routes above and what each delivers from `range(0, 6)` when nothing is ever done.
const under_test = .{
    .{ watched, &[_]u32{ 100, 1, 3, 5, 2, 4 } },
    .{ watched_last, &[_]u32{ 100, 4, 5, 6 } },
    .{ emits_twice, &[_]u32{ 100, 0, 1, 2, 3, 4, 5 } },
};

test "under any `down`, nothing happens after it has said it is done" {
    @setEvalBranchQuota(1_000_000);
    inline for (under_test) |entry| inline for (kinds) |at_start| inline for (kinds) |per_item| inline for (kinds) |at_end| {
        const everything: []const u32 = entry[1];
        const work = pipe(.{Under(entry[0], at_start, per_item, at_end){}});
        const always_asked = comptime answers(at_start) and answers(per_item) and answers(at_end);

        var open: Watch = .{};
        try program(range(u32, 0, 6), work).run(.{&open});
        try open.seen.expect(everything);
        try open.expectNothingAfterDone();

        for (0..everything.len + 2) |nth| for (0..everything.len + 3) |limit| {
            // `limit` one past the end stands for "never".
            const shut_after: ?usize = if (limit == everything.len + 2) null else limit;
            var watch: Watch = .{ .done_on_push = nth, .shut_after = shut_after };
            errdefer std.debug.print("start={s} item={s} end={s} done_on_push={d} shut_after={?d} seen={any} after={d} unasked={d} handled={d} started={d} missed={d}\n", .{
                @tagName(at_start), @tagName(per_item), @tagName(at_end),     nth,                 shut_after,
                watch.seen.slice(), watch.pushed_after, watch.pushed_unasked, watch.handled_after, watch.started_after,
                watch.start_missed,
            });
            try program(range(u32, 0, 6), work).run(.{&watch});
            try watch.expectNothingAfterDone();

            // What arrives is what would have arrived anyway, cut short.
            try std.testing.expect(std.mem.startsWith(u32, everything, watch.seen.slice()));
            // Answering a push ends it there, whatever the `down`. Being
            // done without saying so ends it there if every `down` can be
            // asked, and otherwise no later than the next one that can.
            var at_most: usize = everything.len;
            if (nth != 0) at_most = @min(at_most, nth);
            var at_least = at_most;
            if (shut_after) |after| at_least = @min(at_least, after);
            try std.testing.expect(watch.seen.len <= at_most);
            try std.testing.expect(watch.seen.len >= at_least);
            if (always_asked) try std.testing.expectEqual(at_least, watch.seen.len);
        };
    };
}

fn answers(comptime kind: Kind) bool {
    return kind == .value_answers or kind == .pointer_answers;
}

/// Ends a pipe: the receiver of the test above as a stage.
const Sink = struct {
    pub const zrx_operator = {};
    pub const name = "sink";

    pub fn Out(comptime _: type, comptime In: type) type {
        if (In != u32) @compileError("sink: items must be u32");
        return zrx.End;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            watch: *Watch,

            pub fn init(self: *@This(), _: *const Sink, env: Env) !void {
                self.watch = zrx.di.get(env, *Watch);
            }

            pub fn push(self: *@This(), item: In, _: anytype) !zrx.Flow {
                return self.watch.receive(item, false);
            }
        };
    }
};

fn sumOf(group: []const u32) u32 {
    var sum: u32 = 0;
    for (group) |value| sum += value;
    return sum;
}

const satisfied_cases = zrx.route(.{
    zrx.when(isOdd, pipe(.{ Noting{ .value = 100 }, zrx.tap(touch), take(2), zrx.fold(@as(u32, 10), addUp), zrx.tap(touch) })),
    zrx.otherwise(pipe(.{ Noting{ .value = 200 }, take(1), zrx.fold(@as(u32, 20), addUp), zrx.tap(touch) })),
});

/// Every case is satisfied by what it emits as the run starts.
const satisfied_at_start = zrx.route(.{
    zrx.when(isOdd, pipe(.{ Noting{ .value = 100 }, zrx.tap(touch), take(1), zrx.fold(@as(u32, 10), addUp), zrx.tap(touch) })),
    zrx.otherwise(pipe(.{ Noting{ .value = 200 }, take(1), zrx.fold(@as(u32, 20), addUp), zrx.tap(touch) })),
});

const nested = zrx.route(.{
    zrx.when(isBelowFour, pipe(.{ Noting{ .last = 8 }, watched, zrx.tap(touch) })),
    zrx.otherwise(pipe(.{ Noting{ .value = 300, .last = 9 }, zrx.fold(@as(u32, 0), addUp), zrx.tap(touch) })),
});

/// Pipes that emit as the run starts, while items flow and as the stream
/// ends, from before, inside and after a route.
const shapes = .{
    pipe(.{ Noting{ .last = 7 }, zrx.tap(touch), watched, zrx.tap(touch), Sink{} }),
    pipe(.{ Noting{ .value = 50, .last = 7 }, zrx.tap(touch), watched, Sink{} }),
    pipe(.{ Noting{ .value = 50, .last = 7 }, zrx.tap(touch), Noting{ .value = 60, .last = 8 }, zrx.tap(touch), Sink{} }),
    pipe(.{ Noting{ .last = 7 }, zrx.tap(touch), zrx.batch(2), map(sumOf), zrx.tap(touch), Noting{ .value = 60, .last = 8 }, Sink{} }),
    pipe(.{ Noting{ .last = 7 }, zrx.tap(touch), satisfied_cases, zrx.tap(touch), Sink{} }),
    pipe(.{ Noting{ .value = 50, .last = 7 }, zrx.tap(touch), nested, zrx.tap(touch), Noting{ .last = 6 }, Sink{} }),
    pipe(.{ nested, filter(isOdd), zrx.tap(touch), watched, zrx.tap(touch), Sink{} }),
    pipe(.{ Noting{ .value = 50, .last = 7 }, zrx.tap(touch), satisfied_at_start, zrx.tap(touch), Noting{ .last = 6 }, Sink{} }),
};

/// What each of `shapes` delivers from `range(0, 6)` when the end is never
/// done, worked out by hand.
const deliveries = [_][]const u32{
    &.{ 100, 1, 3, 5, 7, 2, 4 },
    &.{ 100, 1, 3, 5, 7, 2, 54 },
    &.{ 60, 50, 0, 1, 2, 3, 4, 5, 7, 8 },
    &.{ 60, 1, 5, 9, 7, 8 },
    &.{ 111, 220 },
    &.{ 100, 1, 3, 2, 8, 375, 6 },
    &.{ 100, 1, 3, 0, 0 },
    &.{ 110, 220, 6 },
};

test "in any pipe, closing the end after any number of values leaves exactly those, and nothing after" {
    @setEvalBranchQuota(1_000_000);
    inline for (shapes, 0..) |work, shape| {
        // What arrives when the end is never done.
        var open: Watch = .{};
        try program(range(u32, 0, 6), work).run(.{&open});
        try open.expectNothingAfterDone();
        const everything_here = open.seen.slice();
        try std.testing.expectEqualSlices(u32, deliveries[shape], everything_here);

        for (1..everything_here.len + 2) |nth| {
            var watch: Watch = .{ .done_on_push = nth };
            errdefer std.debug.print("shape={d} done_on_push={d} all={any} seen={any} after={d} handled={d} started={d}\n", .{
                shape, nth, everything_here, watch.seen.slice(), watch.pushed_after, watch.handled_after, watch.started_after,
            });
            try program(range(u32, 0, 6), work).run(.{&watch});
            try watch.seen.expect(everything_here[0..@min(nth, everything_here.len)]);
            try watch.expectNothingAfterDone();
        }
    }
}

// --- a stage that does not stop when it is told to ------------------------------

/// Pushes every item twice, whatever the first push was answered.
const Insistent = struct {
    pub const zrx_operator = {};
    pub const name = "insistent";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            pub fn init(_: *@This(), _: *const Insistent, _: Env) !void {}

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                _ = try down.push(item);
                return down.push(item);
            }
        };
    }
};

const Asked = struct { count: usize = 0 };
fn oddCounted(asked: *Asked, value: u32) bool {
    asked.count += 1;
    return value % 2 == 1;
}
fn keep(value: u32) u32 {
    return value;
}

test "a stage that is done keeps answering done to one that pushes regardless" {
    // The chain only keeps late emissions away. While items flow, a stage
    // that ignores `.done` reaches the next one again: `take` drops the
    // item, and a route asks no predicate for it.
    var seen: Numbers = .{};
    var asked: Asked = .{};
    const routed = pipe(.{
        Insistent{},
        zrx.route(.{
            zrx.when(oddCounted, pipe(.{map(keep)})),
            zrx.otherwise(pipe(.{map(keep)})),
        }),
        take(1),
        subscribe(record),
    });
    try program(range(u32, 0, 4), routed).run(.{ &seen, &asked });
    try seen.expect(&.{0});
    try std.testing.expectEqual(@as(usize, 1), asked.count);

    var taken: Numbers = .{};
    try program(range(u32, 0, 4), pipe(.{ Insistent{}, take(3), subscribe(record) })).run(.{&taken});
    try taken.expect(&.{ 0, 0, 1 });
}

// --- finding A -------------------------------------------------------------------

// --- a pipe run by another operator ---------------------------------------------

/// Ends a pipe by running `inner`, a pipe, with a `down` that can be asked as
/// the run starts and one that cannot afterwards.
fn Piped(comptime inner: anytype) type {
    return struct {
        const Op = @This();
        const Inner = @TypeOf(inner);
        const wrapped: Inner = inner;

        pub const zrx_operator = {};
        pub const name = "piped";

        pub fn Out(comptime Env: type, comptime In: type) type {
            if (Inner.Out(Env, In) != u32) @compileError("piped: items must be u32");
            return zrx.End;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                inner: Inner.Stage(Env, In),
                watch: *Watch,

                const Self = @This();

                pub fn init(self: *Self, _: *const Op, env: Env) !void {
                    self.watch = zrx.di.get(env, *Watch);
                    try self.inner.init(&wrapped, env);
                }

                pub fn start(self: *Self, _: anytype) !zrx.Flow {
                    return self.inner.start(Answering{ .watch = self.watch }, {});
                }

                pub fn push(self: *Self, item: In, _: anytype) !zrx.Flow {
                    return self.inner.push(item, PushOnly{ .watch = self.watch });
                }

                pub fn finish(self: *Self, _: anytype) !void {
                    try self.inner.finish(PushOnly{ .watch = self.watch }, {});
                }

                pub fn deinit(self: *Self) void {
                    self.inner.deinit();
                }
            };
        }
    };
}

/// Pipes whose first emission is refused as the run starts and which have
/// more to emit as the stream ends.
const piped = .{
    pipe(.{ Noting{ .value = 100 }, Noting{ .last = 9 } }),
    pipe(.{ watched, Noting{ .last = 9 } }),
    pipe(.{ Noting{ .value = 100 }, zrx.tap(touch), watched_last, zrx.tap(touch), Noting{ .last = 9 } }),
};

test "a pipe remembers that it was told its output is done" {
    // As the run starts the receiver says it is done, and the first value is
    // refused. As the stream ends the pipe is given a `down` that cannot be
    // asked: a final value must not reach it.
    inline for (piped) |inner| {
        var watch: Watch = .{ .shut_after = 0 };
        try program(range(u32, 0, 6), pipe(.{Piped(inner){}})).run(.{&watch});
        try watch.seen.expect(&.{});
        try watch.expectNothingAfterDone();
    }
}
