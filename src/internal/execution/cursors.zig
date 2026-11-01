//! Typed synchronous regions. Known callbacks are direct calls, never a stage
//! interpreter. Resource ownership and graph boundaries live outside the cursor.
const std = @import("std");
const decl = @import("../../data/declarations.zig");
const seq = @import("../../data/sequences.zig");
const cb = @import("../callbacks.zig");
const transforms = @import("../transforms.zig");
const outcomes = @import("../outcomes.zig");

pub fn finite(comptime Input: type) bool {
    const T = decl.Child(Input);
    if (!@hasDecl(T, "node_kind")) return false;
    if (T.node_kind == .slice or T.node_kind == .value or T.node_kind == .iterator) return true;
    if (T.node_kind == .producer or T.node_kind == .queue or T.node_kind == .retained) return false;
    return finite(@FieldType(T, "source"));
}

pub fn Cursor(comptime Input: type, comptime Env: type) type {
    const T = decl.Child(Input);
    if (@hasDecl(T, "node_kind") and T.node_kind == .iterator) {
        const Inner = @FieldType(T, "source");
        return struct {
            input: seq.Cursor(Inner),
            env: *Env,
            pub fn next(self: *@This()) anyerror!?T.Item {
                return outcomes.unwrap(T.Item, try self.nextOutcome());
            }
            pub fn nextOutcome(self: *@This()) anyerror!?outcomes.Outcome(T.Item) {
                try self.env.io().checkCancel();
                return outcomes.next(T.Item, &self.input);
            }
        };
    }
    if (@hasDecl(T, "node_kind") and (T.node_kind == .slice or T.node_kind == .value)) {
        return struct {
            source: T,
            env: *Env,
            index: usize = 0,
            pub fn next(self: *@This()) anyerror!?T.Item {
                return outcomes.unwrap(T.Item, try self.nextOutcome());
            }
            pub fn nextOutcome(self: *@This()) anyerror!?outcomes.Outcome(T.Item) {
                try self.env.io().checkCancel();
                if (comptime T.node_kind == .slice) {
                    if (self.index == self.source.items.len) return null;
                    const value = self.source.items[self.index];
                    self.index += 1;
                    return .{ .value = value };
                } else {
                    if (self.index != 0) return null;
                    self.index = 1;
                    return .{ .value = self.source.value };
                }
            }
        };
    }
    // Reader/view boundary: reuse the audited borrowed iterator conventions.
    if (!@hasDecl(T, "node_kind")) {
        return struct {
            input: seq.Cursor(Input),
            env: *Env,
            pub fn next(self: *@This()) anyerror!?seq.Item(Input) {
                return outcomes.unwrap(seq.Item(Input), try self.nextOutcome());
            }
            pub fn nextOutcome(self: *@This()) anyerror!?outcomes.Outcome(seq.Item(Input)) {
                try self.env.io().checkCancel();
                return outcomes.next(seq.Item(Input), &self.input);
            }
        };
    }
    const Source = @FieldType(T, "source");
    const Base = Cursor(Source, Env);
    const Item = seq.Item(T);
    const scanned = @hasDecl(T, "node_kind") and T.node_kind == .scan;
    return struct {
        input: Base,
        source: T,
        env: *Env,
        count: usize = 0,
        done: bool = false,
        state: if (scanned) Item else void,
        pub fn next(self: *@This()) anyerror!?Item {
            return outcomes.unwrap(Item, try self.nextOutcome());
        }
        pub fn nextOutcome(self: *@This()) anyerror!?outcomes.Outcome(Item) {
            if (self.done) return null;
            if (comptime @hasDecl(T, "node_kind")) {
                if (T.node_kind == .take or T.node_kind == .bounded) {
                    if (T.node_kind == .take and self.count == self.source.limit) {
                        self.done = true;
                        return null;
                    }
                    const item = (try self.input.nextOutcome()) orelse {
                        self.done = true;
                        return null;
                    };
                    const value = switch (item) {
                        .failure => |err| return .{ .failure = err },
                        .value => |value| value,
                    };
                    if (T.node_kind == .bounded and self.count == self.source.limit) {
                        self.done = true;
                        return .{ .failure = error.TooManyItems };
                    }
                    self.count += 1;
                    return .{ .value = value };
                }
                if (T.node_kind == .fold) {
                    var state = self.source.seed;
                    while (try self.input.nextOutcome()) |item| {
                        const value = switch (item) {
                            .failure => |err| {
                                self.done = true;
                                return .{ .failure = err };
                            },
                            .value => |value| value,
                        };
                        const result = cb.invoke(T.callback, self.env, .{ state, value });
                        state = if (@typeInfo(@TypeOf(result)) == .error_union) result catch |err| {
                            self.done = true;
                            return try outcomes.failed(Item, err);
                        } else result;
                    }
                    self.done = true;
                    return .{ .value = state };
                }
                if (T.node_kind == .scan) {
                    const item = (try self.input.nextOutcome()) orelse {
                        self.done = true;
                        return null;
                    };
                    const value = switch (item) {
                        .failure => |err| return .{ .failure = err },
                        .value => |value| value,
                    };
                    self.state = cb.invoke(T.callback, self.env, .{ self.state, value });
                    return .{ .value = self.state };
                }
                if (T.node_kind == .retry) {
                    const item = (try self.input.nextOutcome()) orelse {
                        self.done = true;
                        return null;
                    };
                    const value = switch (item) {
                        .failure => |err| return .{ .failure = err },
                        .value => |value| value,
                    };
                    var result: outcomes.Outcome(Item) = undefined;
                    try T.retry_meta.run(self.source.operators, self.source.policy, self.env, value, &result);
                    return result;
                }
                while (try self.input.nextOutcome()) |item| {
                    const value = switch (item) {
                        .failure => |err| {
                            if (comptime T.node_kind == .recover) {
                                if (outcomes.matches(T.ErrorSet, err))
                                    return .{ .value = cb.invoke(T.callback, self.env, .{@as(T.ErrorSet, @errorCast(err))}) };
                            }
                            return .{ .failure = err };
                        },
                        .value => |value| value,
                    };
                    if (comptime T.node_kind == .recover) return .{ .value = value };
                    if (T.node_kind == .map)
                        return .{ .value = transforms.map(T.functions, self.env, value, 0) catch |err| return try outcomes.failed(Item, err) };
                    if (T.node_kind == .filter) {
                        if (predicates(T.functions, self.env, value) catch |err| return try outcomes.failed(Item, err))
                            return .{ .value = value };
                    } else if (T.node_kind == .tap) {
                        return .{ .value = transforms.tap(T.functions, self.env, value) catch |err| return try outcomes.failed(Item, err) };
                    }
                }
                self.done = true;
                return null;
            }
        }
    };
}

pub fn init(input: anytype, env: anytype) Cursor(@TypeOf(input), @typeInfo(@TypeOf(env)).pointer.child) {
    const Input = @TypeOf(input);
    const T = decl.Child(Input);
    const value = if (@typeInfo(Input) == .pointer and @typeInfo(Input).pointer.size == .one) input.* else input;
    if (comptime @hasDecl(T, "node_kind") and T.node_kind == .iterator)
        return .{ .input = seq.cursor(value.source), .env = env };
    if (comptime @hasDecl(T, "node_kind") and (T.node_kind == .slice or T.node_kind == .value))
        return .{ .source = value, .env = env };
    if (comptime !@hasDecl(T, "node_kind"))
        return .{ .input = seq.cursor(input), .env = env };
    return .{
        .source = value,
        .env = env,
        .input = init(value.source, env),
        .state = if (comptime @hasDecl(T, "node_kind") and T.node_kind == .scan) value.seed else {},
    };
}

fn predicates(comptime functions: anytype, env: anytype, value: anytype) !bool {
    inline for (functions) |predicate| {
        const result = cb.invoke(predicate, env, .{value});
        const keep = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
        if (!keep) return false;
    }
    return true;
}
