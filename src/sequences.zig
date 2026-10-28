const std = @import("std");
const composition = @import("composition.zig");
const SequenceTag = opaque {};

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

fn Each(comptime transforms: anytype) type {
    const functions = composition.functions(transforms, "each");
    return struct {
        pub fn Output(comptime Input: type) type {
            return Mapped(Input, functions);
        }

        pub fn apply(_: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source };
        }
    };
}

fn isView(comptime Source: type) bool {
    return @typeInfo(Source) == .@"struct" and @hasDecl(Source, "sequence_tag") and
        Source.sequence_tag == SequenceTag;
}

fn Item(comptime Source: type) type {
    if (isView(Source)) return Source.Item;
    if (@typeInfo(Source) == .pointer) {
        const info = @typeInfo(Source).pointer;
        if (info.size == .slice) return info.child;
        if (info.size == .one and @typeInfo(info.child) == .array) return @typeInfo(info.child).array.child;
    }
    @compileError("sequence: expected a borrowed slice, pointer-to-array, or zrx view; pass arrays by reference");
}

fn Cursor(comptime Source: type) type {
    if (isView(Source)) return Source.Iterator;
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

fn cursor(source: anytype) Cursor(@TypeOf(source)) {
    if (comptime isView(@TypeOf(source))) return source.iterator();
    return .{ .source = source };
}

fn Filtered(comptime Source: type, comptime predicate: anytype) type {
    const Element = Item(Source);
    // Check compatibility without executing a lazy callback.
    _ = @TypeOf(predicate(@as(Element, undefined)));
    return struct {
        source: Source,
        pub const sequence_tag = SequenceTag;
        pub const Item = Element;
        pub const Iterator = struct {
            input: Cursor(Source),

            pub fn next(self: *@This()) ?Element {
                while (self.input.next()) |value| {
                    if (predicate(value)) return value;
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
        pub const Iterator = struct {
            input: Cursor(Source),

            pub fn next(self: *@This()) ?Element {
                const value = self.input.next() orelse return null;
                return composition.compose(value, functions, 0);
            }
        };

        pub fn iterator(self: @This()) Iterator {
            return .{ .input = cursor(self.source) };
        }
    };
}

/// Collect into borrowed mutable storage, without allocation. On overflow the
/// written prefix remains modified and one additional element has been evaluated.
pub fn collectInto(buffer: anytype) CollectInto(BufferItem(@TypeOf(buffer))) {
    return .{ .buffer = buffer };
}

fn BufferItem(comptime Buffer: type) type {
    if (@typeInfo(Buffer) == .pointer) {
        const info = @typeInfo(Buffer).pointer;
        if (!info.attrs.@"const") {
            if (info.size == .slice) return info.child;
            if (info.size == .one and @typeInfo(info.child) == .array) return @typeInfo(info.child).array.child;
        }
    }
    @compileError("collectInto: expected a mutable slice or pointer-to-array");
}

fn CollectInto(comptime Element: type) type {
    return struct {
        buffer: []Element,

        pub fn Output(comptime Input: type) type {
            _ = @TypeOf(@as(Element, @as(Item(Input), undefined)));
            return error{NoSpaceLeft}![]Element;
        }

        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            var input = cursor(source);
            var written: usize = 0;
            while (input.next()) |value| {
                if (written == self.buffer.len) return error.NoSpaceLeft;
                self.buffer[written] = value;
                written += 1;
            }
            return self.buffer[0..written];
        }
    };
}

/// Allocate an owned result with the supplied standard allocator. Free the
/// returned slice with the same allocator; source storage remains borrowed.
pub fn collectAlloc(allocator: std.mem.Allocator) CollectAlloc {
    return .{ .allocator = allocator };
}

const CollectAlloc = struct {
    allocator: std.mem.Allocator,

    pub fn Output(comptime Input: type) type {
        return std.mem.Allocator.Error![]Item(Input);
    }

    pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
        var result: std.ArrayList(Item(@TypeOf(source))) = .empty;
        errdefer result.deinit(self.allocator);
        var input = cursor(source);
        while (input.next()) |value| try result.append(self.allocator, value);
        return result.toOwnedSlice(self.allocator);
    }
};
