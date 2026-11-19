//! JSON text for the items of a pipe, on top of `std.json`.
//!
//!     const archive = pipe(.{
//!         map(json.encode(.{})),
//!         write(Archive, "{f}\n"),
//!     });
//!
//! Nothing here is known to the core: `encode` is a handler like any other.
const std = @import("std");

/// A handler that maps an item to its JSON text: `map(json.encode(.{}))`.
/// The result is a `std.json.Formatter` holding a copy of the item; write
/// it with `{f}`, as in `write(Role, "{f}\n")` for JSON lines. `options`
/// are those of `std.json.Stringify`, for example
/// `.{ .emit_null_optional_fields = false }`.
pub fn encode(comptime options: std.json.Stringify.Options) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) std.json.Formatter(@TypeOf(args[0])) {
            return std.json.fmt(args[0], options);
        }
    };
}
