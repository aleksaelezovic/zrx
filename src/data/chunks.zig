//! Owned bounded sequence values. Referents of element values remain shallow.
//! Callers must keep len <= capacity. Slice/pointer-array operator inputs remain
//! borrowed; their referents must stay valid and unchanged through consumption.
const std = @import("std");
const Tag = opaque {};

pub fn Chunk(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0 or @sizeOf(T) == 0)
        @compileError("Chunk: capacity and element size must be positive");
    return struct {
        pub const chunk_tag = Tag;
        pub const Element = T;
        pub const max_items = capacity;
        items: [capacity]T = undefined,
        len: usize = 0,

        pub fn fromSlice(values: []const T) error{ChunkTooLong}!@This() {
            if (values.len > capacity) return error.ChunkTooLong;
            var result: @This() = .{};
            @memcpy(result.items[0..values.len], values);
            result.len = values.len;
            return result;
        }

        pub fn slice(self: *const @This()) []const T {
            std.debug.assert(self.len <= capacity);
            return self.items[0..self.len];
        }
    };
}

pub fn isChunk(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "chunk_tag") and T.chunk_tag == Tag;
}

pub fn Element(comptime T: type) type {
    if (isChunk(T)) return T.Element;
    return switch (@typeInfo(T)) {
        .array => |a| a.child,
        .pointer => |p| if (p.size == .slice) p.child else if (p.size == .one and @typeInfo(p.child) == .array) @typeInfo(p.child).array.child else invalid(),
        else => invalid(),
    };
}

fn invalid() noreturn {
    @compileError("chunk operator: expected array, slice, pointer-to-array or Chunk items");
}

// Take a pointer so array/Chunk storage stays in the caller, not a temporary.
pub fn slice(value: anytype) []const Element(@typeInfo(@TypeOf(value)).pointer.child) {
    const T = @typeInfo(@TypeOf(value)).pointer.child;
    if (comptime isChunk(T)) return value.slice();
    if (comptime @typeInfo(T) == .array) return value;
    return value.*;
}
