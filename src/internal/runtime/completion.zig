//! Private completion credit for the single-outstanding-request HTTP runtime.
//! Not an inferred payload destructor or general ownership protocol.
const std = @import("std");

pub const Token = struct {
    context: *anyopaque,
    generation: usize,
    release_fn: *const fn (*anyopaque, usize) void,

    pub fn release(self: Token) void {
        self.release_fn(self.context, self.generation);
    }
};

pub const Owner = struct {
    context: *anyopaque,
    acquire_fn: *const fn (*anyopaque) std.Io.Cancelable!Token,
    peek_fn: *const fn (*anyopaque) Token,
    abort_fn: *const fn (*anyopaque) void,

    // Publication admission can close before the forwarding task itself is
    // canceled. Existing credits still release normally after interruption.
    pub fn acquire(self: Owner) std.Io.Cancelable!Token {
        return self.acquire_fn(self.context);
    }
    pub fn peek(self: Owner) Token {
        return self.peek_fn(self.context);
    }
    pub fn abort(self: Owner) void {
        self.abort_fn(self.context);
    }
};
