//! Per-item operators: each one is a small state plus a `push`.
const std = @import("std");
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const Flow = core.Flow;
const End = core.End;
const lift = core.lift;

/// Replaces each item with `handler(deps..., item)`. A returned error fails the run.
pub fn map(comptime handler: anytype) Map(handler) {
    return .{};
}

fn Map(comptime handler: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "map";

        pub fn Out(comptime Env: type, comptime In: type) type {
            const T = di.Payload(di.Bound(name, handler, Env, &.{In}).Return);
            if (T == void) @compileError("map: handler returns no value; use tap(...) for an effect that keeps the item, or subscribe(...) to end the pipe");
            return T;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, handler, Env, &.{In});
            return struct {
                call: Call,

                pub fn init(self: *@This(), _: *const Op, env: Env) !void {
                    self.call = .init(env);
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    return down.push(try lift(self.call.call(.{item})));
                }
            };
        }
    };
}

/// Keeps the items for which `predicate(deps..., item)` is true.
pub fn filter(comptime predicate: anytype) Filter(predicate) {
    return .{};
}

fn Filter(comptime predicate: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "filter";

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectReturn(name, "predicate", di.Bound(name, predicate, Env, &.{In}).Return, bool);
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, predicate, Env, &.{In});
            return struct {
                call: Call,

                pub fn init(self: *@This(), _: *const Op, env: Env) !void {
                    self.call = .init(env);
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    if (!try lift(self.call.call(.{item}))) return .more;
                    return down.push(item);
                }
            };
        }
    };
}

/// Runs `handler(deps..., item)` for its effect and passes the item on unchanged.
pub fn tap(comptime handler: anytype) Tap(handler) {
    return .{};
}

fn Tap(comptime handler: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "tap";

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectReturn(name, "handler", di.Bound(name, handler, Env, &.{In}).Return, void);
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, handler, Env, &.{In});
            return struct {
                call: Call,

                pub fn init(self: *@This(), _: *const Op, env: Env) !void {
                    self.call = .init(env);
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    try lift(self.call.call(.{item}));
                    return down.push(item);
                }
            };
        }
    };
}

/// Running accumulation: emits `state = reducer(deps..., state, item)` after every item.
pub fn scan(seed: anytype, comptime reducer: anytype) Accumulate(.scan, State(reducer, @TypeOf(seed)), reducer) {
    return .{ .seed = seed };
}

/// Final accumulation: emits the last state once, when the stream ends
/// (the seed itself if there were no items).
pub fn fold(seed: anytype, comptime reducer: anytype) Accumulate(.fold, State(reducer, @TypeOf(seed)), reducer) {
    return .{ .seed = seed };
}

/// The accumulator type: the reducer's declared state parameter, else the seed's type.
fn State(comptime reducer: anytype, comptime Seed: type) type {
    if (!di.isHandler(reducer)) @compileError("scan/fold: expected a reducer `fn (deps..., state, item) state`, got `" ++ @typeName(@TypeOf(reducer)) ++ "`");
    return di.Param(reducer, 2, 0) orelse Seed;
}

fn Accumulate(comptime kind: enum { scan, fold }, comptime A: type, comptime reducer: anytype) type {
    return struct {
        seed: A,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = @tagName(kind);

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectReturn(name, "reducer", di.Bound(name, reducer, Env, &.{ A, In }).Return, A);
            return A;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, reducer, Env, &.{ A, In });
            return struct {
                call: Call,
                state: A,

                pub fn init(self: *@This(), op: *const Op, env: Env) !void {
                    self.* = .{ .call = .init(env), .state = op.seed };
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    self.state = try lift(self.call.call(.{ self.state, item }));
                    return if (kind == .scan) down.push(self.state) else .more;
                }

                pub fn finish(self: *@This(), down: anytype) !void {
                    if (kind == .fold) _ = try down.push(self.state);
                }
            };
        }
    };
}

/// Passes the first `count` items, then tells upstream to stop.
pub fn take(count: usize) Take {
    return .{ .count = count };
}

const Take = struct {
    count: usize,

    pub const zrx_operator = {};
    pub const name = "take";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            remaining: usize,

            pub fn init(self: *@This(), op: *const Take, _: Env) !void {
                self.remaining = op.count;
            }

            pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                if (self.remaining == 0) return .done;
                self.remaining -= 1;
                if (try down.push(item) == .done) return .done;
                return if (self.remaining == 0) .done else .more;
            }
        };
    }
};

/// Drops the first `count` items.
pub fn skip(count: usize) Skip {
    return .{ .count = count };
}

const Skip = struct {
    count: usize,

    pub const zrx_operator = {};
    pub const name = "skip";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            remaining: usize,

            pub fn init(self: *@This(), op: *const Skip, _: Env) !void {
                self.remaining = op.count;
            }

            pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                if (self.remaining != 0) {
                    self.remaining -= 1;
                    return .more;
                }
                return down.push(item);
            }
        };
    }
};

/// Passes items until `predicate(deps..., item)` is first false, then tells upstream to stop.
pub fn takeWhile(comptime predicate: anytype) TakeWhile(predicate) {
    return .{};
}

fn TakeWhile(comptime predicate: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "takeWhile";

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectReturn(name, "predicate", di.Bound(name, predicate, Env, &.{In}).Return, bool);
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, predicate, Env, &.{In});
            return struct {
                call: Call,
                open: bool,

                pub fn init(self: *@This(), _: *const Op, env: Env) !void {
                    self.* = .{ .call = .init(env), .open = true };
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    if (!self.open) return .done;
                    if (!try lift(self.call.call(.{item}))) {
                        self.open = false;
                        return .done;
                    }
                    return down.push(item);
                }
            };
        }
    };
}

/// Emits the elements of each array or slice item, in order.
pub fn flatten() Flatten {
    return .{};
}

const Flatten = struct {
    pub const zrx_operator = {};
    pub const name = "flatten";

    pub fn Out(comptime _: type, comptime In: type) type {
        return switch (@typeInfo(In)) {
            .array => |array| array.child,
            .pointer => |pointer| switch (pointer.size) {
                .slice => pointer.child,
                .one => switch (@typeInfo(pointer.child)) {
                    .array => |array| array.child,
                    else => notASequence(In),
                },
                else => notASequence(In),
            },
            else => notASequence(In),
        };
    }

    fn notASequence(comptime In: type) noreturn {
        @compileError("flatten: items must be arrays or slices, got `" ++ @typeName(In) ++ "`");
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            pub fn init(_: *@This(), _: *const Flatten, _: Env) !void {}

            pub fn push(_: *@This(), item: In, down: anytype) !Flow {
                for (item) |element| {
                    if (try down.push(element) == .done) return .done;
                }
                return .more;
            }
        };
    }
};

/// Requires `R` to be `Want` or `E!Want`.
pub fn expectReturn(comptime who: []const u8, comptime what: []const u8, comptime R: type, comptime Want: type) void {
    if (di.Payload(R) != Want) @compileError(
        who ++ ": " ++ what ++ " must return `" ++ @typeName(Want) ++ "` or `E!" ++ @typeName(Want) ++ "`, got `" ++ @typeName(R) ++ "`",
    );
}
