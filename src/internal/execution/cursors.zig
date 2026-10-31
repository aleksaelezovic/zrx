//! Typed synchronous regions. Known callbacks are direct calls, never a stage
//! interpreter. Resource ownership and graph boundaries live outside the cursor.
const std = @import("std");
const decl = @import("../../data/declarations.zig");
const seq = @import("../../data/sequences.zig");
const cb = @import("../callbacks.zig");
const composition = @import("../composition.zig");

pub fn finite(comptime Input: type) bool {
    const T = decl.Child(Input);
    if (!@hasDecl(T, "node_kind") and !@hasDecl(T, "declaration_kind")) return false;
    if (@hasDecl(T, "node_kind")) {
        if (T.node_kind == .slice or T.node_kind == .value) return true;
        if (T.node_kind == .iterator) return true;
        if (T.node_kind == .producer or T.node_kind == .borrowed) return false;
    } else if (T.declaration_kind != .taken and T.declaration_kind != .bounded) return false;
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
                try self.env.io().checkCancel();
                return if (comptime seq.isFallible(Inner)) try self.input.next() else self.input.next();
            }
        };
    }
    if (@hasDecl(T, "node_kind") and (T.node_kind == .slice or T.node_kind == .value)) {
        return struct {
            source: T,
            env: *Env,
            index: usize = 0,
            pub fn next(self: *@This()) anyerror!?T.Item {
                try self.env.io().checkCancel();
                if (comptime T.node_kind == .slice) {
                    if (self.index == self.source.items.len) return null;
                    const value = self.source.items[self.index];
                    self.index += 1;
                    return @as(?T.Item, value);
                } else {
                    if (self.index != 0) return null;
                    self.index = 1;
                    return @as(?T.Item, self.source.value);
                }
            }
        };
    }
    // Reader/view boundary: reuse the audited borrowed iterator conventions.
    if (!@hasDecl(T, "node_kind") and !@hasDecl(T, "declaration_kind")) {
        return struct {
            input: seq.Cursor(Input),
            env: *Env,
            pub fn next(self: *@This()) anyerror!?seq.Item(Input) {
                try self.env.io().checkCancel();
                return if (comptime seq.isFallible(Input)) try self.input.next() else self.input.next();
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
            if (self.done) return null;
            if (comptime @hasDecl(T, "node_kind")) {
                if (T.node_kind == .take or T.node_kind == .bounded) {
                    if (T.node_kind == .take and self.count == self.source.limit) {
                        self.done = true;
                        return null;
                    }
                    const value = (try self.input.next()) orelse {
                        self.done = true;
                        return null;
                    };
                    if (T.node_kind == .bounded and self.count == self.source.limit) return error.TooManyItems;
                    self.count += 1;
                    return @as(?Item, value);
                }
                if (T.node_kind == .fold) {
                    var state = self.source.seed;
                    while (try self.input.next()) |value| {
                        const result = cb.invoke(T.callback, self.env, .{ state, value });
                        state = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
                    }
                    self.done = true;
                    return @as(?Item, state);
                }
                if (T.node_kind == .scan) {
                    const value = (try self.input.next()) orelse {
                        self.done = true;
                        return null;
                    };
                    self.state = cb.invoke(T.callback, self.env, .{ self.state, value });
                    return @as(?Item, self.state);
                }
                while (try self.input.next()) |value| {
                    if (T.node_kind == .map)
                        return @as(?Item, try compose(T.functions, self.env, value, 0));
                    if (T.node_kind == .filter) {
                        if (try predicates(T.functions, self.env, value)) return @as(?Item, value);
                    } else if (T.node_kind == .tap) {
                        inline for (T.functions) |effect| {
                            const result = cb.invoke(effect, self.env, .{value});
                            if (@typeInfo(@TypeOf(result)) == .error_union) try result;
                        }
                        return @as(?Item, value);
                    }
                }
                self.done = true;
                return null;
            } else {
                if (T.declaration_kind == .taken and self.count == self.source.limit) {
                    self.done = true;
                    return null;
                }
                const value = (try self.input.next()) orelse {
                    self.done = true;
                    return null;
                };
                if (T.declaration_kind == .bounded and self.count == self.source.limit)
                    return error.TooManyItems;
                self.count += 1;
                return @as(?Item, value);
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
    if (comptime !@hasDecl(T, "node_kind") and !@hasDecl(T, "declaration_kind"))
        return .{ .input = seq.cursor(input), .env = env };
    return .{
        .source = value,
        .env = env,
        .input = init(value.source, env),
        .state = if (comptime @hasDecl(T, "node_kind") and T.node_kind == .scan) value.seed else {},
    };
}

fn Output(comptime functions: anytype, comptime Input: type, comptime index: usize) type {
    cb.validate(functions[index], &.{Input});
    const Next = composition.Payload(cb.Info(functions[index], 1).Return);
    return if (index + 1 == functions.len) Next else Output(functions, Next, index + 1);
}

fn compose(comptime functions: anytype, env: anytype, value: anytype, comptime index: usize) anyerror!Output(functions, @TypeOf(value), index) {
    const result = cb.invoke(functions[index], env, .{value});
    const next = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
    return if (index + 1 == functions.len) next else try compose(functions, env, next, index + 1);
}

fn predicates(comptime functions: anytype, env: anytype, value: anytype) !bool {
    inline for (functions) |predicate| {
        const result = cb.invoke(predicate, env, .{value});
        const keep = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
        if (!keep) return false;
    }
    return true;
}
