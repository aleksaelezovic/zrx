// Test-only eager traversal for inspecting the private cursor/transport backend.
// Application terminal effects use ops/ and the run executor.
const composition = @import("composition.zig");
const sequences = @import("../data/sequences.zig");
const std = @import("std");

// Private fixture helpers for checking cursor output and transport lifetimes.
// They are not exported from zrx and are not application collection terminals.
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
            _ = @TypeOf(@as(Element, @as(sequences.Item(Input), undefined)));
            return (error{NoSpaceLeft} || sequences.Errors(Input))![]Element;
        }
        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            var input = sequences.cursor(source);
            var written: usize = 0;
            while (if (comptime sequences.isFallible(@TypeOf(source))) try input.next() else input.next()) |value| {
                if (written == self.buffer.len) return error.NoSpaceLeft;
                self.buffer[written] = value;
                written += 1;
            }
            return self.buffer[0..written];
        }
    };
}

pub fn collectAlloc(allocator: std.mem.Allocator) CollectAlloc {
    return .{ .allocator = allocator };
}

const CollectAlloc = struct {
    allocator: std.mem.Allocator,
    pub fn Output(comptime Input: type) type {
        return (std.mem.Allocator.Error || sequences.Errors(Input))![]sequences.Item(Input);
    }
    pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
        var result: std.ArrayList(sequences.Item(@TypeOf(source))) = .empty;
        errdefer result.deinit(self.allocator);
        var input = sequences.cursor(source);
        while (if (comptime sequences.isFallible(@TypeOf(source))) try input.next() else input.next()) |value|
            try result.append(self.allocator, value);
        return result.toOwnedSlice(self.allocator);
    }
};

pub fn forEach(comptime effect: anytype) Visit(effect, false) {
    return .{ .capability = {} };
}

pub fn forEachWith(capability: anytype, comptime effect: anytype) Visit(effect, true) {
    return .{ .capability = capability };
}

fn Visit(comptime effect: anytype, comptime with_capability: bool) type {
    const info = composition.callbackInfo(effect, "test traversal", if (with_capability) 2 else 1);
    const Capability = if (with_capability) info.param_types[0].? else void;
    const Argument = info.param_types[if (with_capability) 1 else 0].?;
    const Return = info.return_type.?;
    const EffectErrors = if (Return == void) error{} else @typeInfo(Return).error_union.error_set;
    return struct {
        capability: Capability,
        pub fn Output(comptime Input: type) type {
            _ = @TypeOf(@as(Argument, @as(sequences.Item(Input), undefined)));
            return if (Return != void or sequences.isFallible(Input))
                (EffectErrors || sequences.Errors(Input))!void
            else
                void;
        }
        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            var cursor = sequences.cursor(source);
            while (if (comptime sequences.isFallible(@TypeOf(source))) try cursor.next() else cursor.next()) |value| {
                const result = if (with_capability) effect(self.capability, value) else effect(value);
                if (Return != void) try result;
            }
        }
    };
}
