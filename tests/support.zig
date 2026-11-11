//! Shared test helpers.
const std = @import("std");

/// A fixed-capacity log of the items a pipeline delivered.
pub fn Recorder(comptime T: type) type {
    return struct {
        items: [256]T = undefined,
        len: usize = 0,

        pub fn add(self: *@This(), item: T) void {
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *const @This()) []const T {
            return self.items[0..self.len];
        }

        pub fn expect(self: *const @This(), expected: []const T) !void {
            try std.testing.expectEqualSlices(T, expected, self.slice());
        }
    };
}

/// A handler that appends each item to the injected `*Recorder(T)`.
pub fn record(comptime T: type) fn (*Recorder(T), T) void {
    return struct {
        fn add(recorder: *Recorder(T), item: T) void {
            recorder.add(item);
        }
    }.add;
}
