//! Borrowed cursor/type machinery shared by operators and graph lowering.
//! Slice and pointer-to-array views allocate nothing. A fresh cursor starts at
//! the beginning, copies retain their current position, and repeated traversal
//! rereads source storage and reruns callbacks. Arrays by value are rejected.
//! Iterator/queue adapters instead borrow consuming positions, never rewind.
//!
//! Storage must outlive views, cursors, and borrowed results. Do not mutate it
//! during traversal. Items are shallow: optional/error-union elements remain
//! data, and pointer/slice referents keep their own lifetime requirements.
//! Graph declarations require run; they cannot expose a live cursor directly.
const composition = @import("../internal/composition.zig");
const signal_kind = @import("../internal/signal_kind.zig");
pub const SequenceTag = opaque {};
pub const GraphTag = opaque {};

pub fn isGraph(comptime Input: type) bool {
    const T = if (@typeInfo(Input) == .pointer and @typeInfo(Input).pointer.size == .one)
        @typeInfo(Input).pointer.child
    else
        Input;
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasDecl(T, "graph_tag") and T.graph_tag == GraphTag) return true;
    return false;
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

pub fn NextResult(comptime Source: type, comptime Element: type) type {
    return if (isFallible(Source)) Errors(Source)!?Element else ?Element;
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
