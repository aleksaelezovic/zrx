//! Shared bounded framing state. No transport, allocation, I/O or callbacks.
const chunks = @import("../data/chunks.zig");

pub const Options = struct {
    max_items: usize,
    empty: enum { emit, skip } = .emit,
    final: enum { emit_nonempty, discard } = .emit_nonempty,
};

pub fn State(comptime T: type, comptime options: Options) type {
    const Item = chunks.Chunk(T, options.max_items);
    return struct {
        pending: Item = .{},

        pub fn feed(self: *@This(), element: T, delimiter: bool) error{FrameTooLong}!?Item {
            if (delimiter) {
                if (self.pending.len == 0 and options.empty == .skip) return null;
                const result = self.pending;
                self.pending = .{};
                return result;
            }
            if (self.pending.len == options.max_items) return error.FrameTooLong;
            self.pending.items[self.pending.len] = element;
            self.pending.len += 1;
            return null;
        }

        pub fn finish(self: *@This()) ?Item {
            defer self.pending = .{};
            return if (options.final == .emit_nonempty and self.pending.len != 0) self.pending else null;
        }
    };
}
