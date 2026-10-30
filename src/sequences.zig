const composition = @import("composition.zig");
const signal_kind = @import("signal_kind.zig");
pub const SequenceTag = opaque {};
pub const GraphTag = opaque {};

pub fn isGraph(comptime Input: type) bool {
    const T = if (@typeInfo(Input) == .pointer and @typeInfo(Input).pointer.size == .one)
        @typeInfo(Input).pointer.child
    else
        Input;
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasDecl(T, "graph_tag") and T.graph_tag == GraphTag) return true;
    return @hasDecl(T, "declaration_source") and isGraph(T.declaration_source);
}

/// Construct a borrowed, lazy filtered view. The predicate is not run until next().
pub fn filter(comptime predicate: anytype) Filter(predicate) {
    return .{};
}

fn Filter(comptime predicate: anytype) type {
    _ = composition.PredicateInput(predicate, "filter");
    return struct {
        pub fn Output(comptime Input: type) type {
            return Filtered(Input, predicate);
        }

        pub fn apply(_: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source };
        }
    };
}

/// Map individual elements lazily, preserving optional/error-union elements as values.
pub fn each(comptime transforms: anytype) Each(transforms) {
    return .{};
}

/// Fail on the first excess item, without forwarding it or truncating input.
pub fn maxItems(limit: usize) MaxItems {
    return .{ .limit = limit };
}

/// Retain a shallow final suffix, publishing it only after successful input end.
/// Ring storage belongs to run; even finite inputs cannot iterate this directly.
pub fn takeLast(limit: usize) TakeLast {
    return .{ .limit = limit };
}

const TakeLast = struct {
    limit: usize,

    pub fn Output(comptime Input: type) type {
        const Element = Item(Input);
        return struct {
            source: Input,
            limit: usize,
            pub const sequence_tag = SequenceTag;
            pub const graph_tag = GraphTag;
            pub const Item = Element;
            pub const declaration_source = Input;
            pub const declaration_kind = .retained;
        };
    }

    pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
        return .{ .source = source, .limit = self.limit };
    }
};

const MaxItems = struct {
    limit: usize,

    pub fn Output(comptime Input: type) type {
        return Bounded(Input);
    }

    pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
        return .{ .source = source, .limit = self.limit };
    }
};

fn Bounded(comptime Source: type) type {
    const Element = Item(Source);
    return struct {
        source: Source,
        limit: usize,
        pub const sequence_tag = SequenceTag;
        pub const Item = Element;
        pub const declaration_source = Source;
        pub const declaration_kind = .bounded;
        pub const Iterator = struct {
            input: Cursor(Source),
            remaining: usize,

            pub fn next(self: *@This()) (Errors(Source) || error{TooManyItems})!?Element {
                const value = (if (comptime isFallible(Source)) try self.input.next() else self.input.next()) orelse return null;
                if (self.remaining == 0) return error.TooManyItems;
                self.remaining -= 1;
                return @as(?Element, value);
            }
        };

        pub fn iterator(self: @This()) Iterator {
            return .{ .input = cursor(self.source), .remaining = self.limit };
        }
    };
}

fn Each(comptime transforms: anytype) type {
    const functions = composition.functions(transforms, "each");
    return struct {
        pub fn Output(comptime Input: type) type {
            if (signal_kind.isSignal(Input)) @compileError("each: use map for signals, or each on values(signal)");
            return Mapped(Input, functions);
        }

        pub fn apply(_: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source };
        }
    };
}

fn ViewType(comptime Source: type) ?type {
    const T = if (@typeInfo(Source) == .pointer and @typeInfo(Source).pointer.size == .one)
        @typeInfo(Source).pointer.child
    else
        Source;
    return if (@typeInfo(T) == .@"struct" and @hasDecl(T, "sequence_tag") and
        T.sequence_tag == SequenceTag) T else null;
}

pub fn Item(comptime Source: type) type {
    if (signal_kind.isSignal(Source)) @compileError("signal: use values(signal) for stream operators and terminal effects");
    if (ViewType(Source)) |View| return View.Item;
    if (@typeInfo(Source) == .pointer) {
        const info = @typeInfo(Source).pointer;
        if (info.size == .slice) return info.child;
        if (info.size == .one and @typeInfo(info.child) == .array) return @typeInfo(info.child).array.child;
    }
    @compileError("sequence: expected a borrowed slice, pointer-to-array, or zrx view; pass arrays by reference");
}

pub fn Cursor(comptime Source: type) type {
    if (isGraph(Source))
        @compileError("stream declarations execute through run; use a terminal effect instead of direct iteration");
    if (ViewType(Source)) |View| return View.Iterator;
    const Element = Item(Source);
    // A slice for-loop has no resumable cursor. Keep only its traversal state
    // for these lazy adapters, using Zig's usual next() convention.
    return struct {
        source: []const Element,
        index: usize = 0,

        pub fn next(self: *@This()) ?Element {
            if (self.index == self.source.len) return null;
            const value = self.source[self.index];
            self.index += 1;
            return value;
        }
    };
}

pub fn cursor(source: anytype) Cursor(@TypeOf(source)) {
    if (comptime ViewType(@TypeOf(source)) != null) return source.iterator();
    return .{ .source = source };
}

pub fn isFallible(comptime Source: type) bool {
    return @typeInfo(@typeInfo(@TypeOf(Cursor(Source).next)).@"fn".return_type.?) == .error_union;
}

pub fn Errors(comptime Source: type) type {
    const Return = @typeInfo(@TypeOf(Cursor(Source).next)).@"fn".return_type.?;
    return if (@typeInfo(Return) == .error_union) @typeInfo(Return).error_union.error_set else error{};
}

fn NextResult(comptime Source: type, comptime Element: type) type {
    return if (isFallible(Source)) Errors(Source)!?Element else ?Element;
}

/// Borrow a conventional mutable iterator. Construction never calls next.
/// New view iterators share this input's position; they do not rewind or clone it.
pub fn fromIterator(input: anytype) PullView(BorrowedCursor(@TypeOf(input))) {
    return .{ .input = .{ .input = input } };
}

fn BorrowedCursor(comptime Pointer: type) type {
    const contract = "fromIterator: expected a mutable single-item pointer to an iterator with next(self) returning ?T or E!?T";
    if (@typeInfo(Pointer) != .pointer or @typeInfo(Pointer).pointer.size != .one or
        @typeInfo(Pointer).pointer.attrs.@"const")
        @compileError(contract);
    const Input = @typeInfo(Pointer).pointer.child;
    if (@typeInfo(Input) != .@"struct" or !@hasDecl(Input, "next"))
        @compileError(contract);
    const info = switch (@typeInfo(@TypeOf(Input.next))) {
        .@"fn" => |info| info,
        else => @compileError(contract),
    };
    if (info.is_generic or info.attrs.varargs or info.param_types.len != 1 or
        info.param_types[0] != Pointer or info.return_type == null)
        @compileError(contract);
    const Return = info.return_type.?;
    const Payload = composition.Payload(Return);
    if (@typeInfo(Payload) != .optional) @compileError(contract);
    return struct {
        input: Pointer,

        pub fn next(self: *@This()) Return {
            return self.input.next();
        }
    };
}

// Internal bridge for adapters whose cursor owns its small traversal state.
pub fn PullView(comptime Input: type) type {
    const Return = @typeInfo(@TypeOf(Input.next)).@"fn".return_type.?;
    const Element = @typeInfo(composition.Payload(Return)).optional.child;
    return struct {
        input: Input,
        pub const sequence_tag = SequenceTag;
        pub const Item = Element;
        pub const Iterator = Input;

        pub fn iterator(self: @This()) Iterator {
            return self.input;
        }
    };
}

fn Filtered(comptime Source: type, comptime predicate: anytype) type {
    const Element = Item(Source);
    // Check compatibility without executing a lazy callback.
    _ = @TypeOf(predicate(@as(Element, undefined)));
    return struct {
        source: Source,
        pub const sequence_tag = SequenceTag;
        pub const Item = Element;
        pub const declaration_source = Source;
        pub const declaration_kind = .filtered;
        pub const declaration_predicate = predicate;
        pub const Iterator = struct {
            input: Cursor(Source),

            pub fn next(self: *@This()) NextResult(Source, Element) {
                while (if (comptime isFallible(Source)) try self.input.next() else self.input.next()) |value| {
                    if (predicate(value)) return @as(?Element, value);
                }
                return null;
            }
        };

        pub fn iterator(self: @This()) Iterator {
            return .{ .input = cursor(self.source) };
        }
    };
}

fn Mapped(comptime Source: type, comptime functions: anytype) type {
    const Element = block: {
        var Current = Item(Source);
        for (functions) |transform| Current = @TypeOf(transform(@as(Current, undefined)));
        break :block Current;
    };
    return struct {
        source: Source,
        pub const sequence_tag = SequenceTag;
        pub const Item = Element;
        pub const declaration_source = Source;
        pub const declaration_kind = .mapped;
        pub const declaration_functions = functions;
        pub const Iterator = struct {
            input: Cursor(Source),

            pub fn next(self: *@This()) NextResult(Source, Element) {
                const value = (if (comptime isFallible(Source)) try self.input.next() else self.input.next()) orelse return null;
                // The optional boundary keeps element errors/nulls inside the item.
                return @as(?Element, composition.compose(value, functions, 0));
            }
        };

        pub fn iterator(self: @This()) Iterator {
            return .{ .input = cursor(self.source) };
        }
    };
}

/// Eager left fold. The reducer returns exactly its accumulator type, never an
/// outer error union. Each application starts from a shallow copy of the seed.
pub fn fold(initial: anytype, comptime reducer: anytype) Fold(reducer, false) {
    return .{ .initial = initial };
}

/// Eager left fold with an explicit per-item try. Stops at the first reducer
/// error under either executor; no rollback or accumulator cleanup is performed.
pub fn tryFold(initial: anytype, comptime reducer: anytype) Fold(reducer, true) {
    return .{ .initial = initial };
}

fn Fold(comptime reducer: anytype, comptime fallible: bool) type {
    const name = if (fallible) "tryFold" else "fold";
    const info = composition.callbackInfo(reducer, name ++ ": reducer", 2);
    const State = info.param_types[0].?;
    const Result = info.return_type.?;
    if (!fallible and @typeInfo(Result) == .error_union) {
        @compileError("fold: reducer must not return an outer error union; use tryFold");
    }
    if (@typeInfo(State) == .error_union) {
        @compileError(name ++ ": accumulator must not be an outer error union; wrap error data in a struct");
    }
    if (fallible) {
        if (@typeInfo(Result) != .error_union) {
            @compileError("tryFold: reducer must return an error union with the accumulator type as payload");
        }
        if (@typeInfo(Result).error_union.payload != State) {
            @compileError("tryFold: reducer success payload must exactly match the accumulator type");
        }
    } else if (Result != State) {
        @compileError("fold: reducer result must exactly match the accumulator type");
    }
    return struct {
        initial: State,

        pub fn Output(comptime Input: type) type {
            if (isGraph(Input)) {
                @compileError(name ++ ": run-backed sources cannot be reduced eagerly; use a terminal flow");
            }
            if (isFallible(Input)) {
                @compileError(name ++ ": fallible sequence cursors are not supported; reduce an infallible finite source");
            }
            // Check even empty sources, without running callbacks.
            _ = @TypeOf(reducer(@as(State, undefined), @as(Item(Input), undefined)));
            return Result;
        }

        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            var state = self.initial;
            var input = cursor(source);
            while (input.next()) |value| {
                state = if (comptime fallible) try reducer(state, value) else reducer(state, value);
            }
            return state;
        }
    };
}
