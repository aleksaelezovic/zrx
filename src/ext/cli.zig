//! What a command-line program writes around its run: the exit status, and
//! the handler that makes one of the failure of the run.
//!
//!     pub fn main(init: std.process.Init) u8 {
//!         var exit: cli.Exit = .{};
//!         app.run(.{
//!             init.io,
//!             &exit,
//!             rescue(cli.fail(.{})).provide(.{stderr(256)}),
//!         });
//!         return exit.code;
//!     }
//!
//! Nothing here is known to the core: `Exit` is a dependency like any other
//! and `fail` a handler like any other. Nothing here ends the process
//! either: `main` returns the status.
const std = @import("std");
const di = @import("../di.zig");
const Stderr = @import("../io.zig").Stderr;

/// How a program ended, for `main` to return. A run returns nothing, so the
/// status is an effect: `main` passes a `*Exit` to `run`, and whoever has
/// something to say about the outcome asks for it, as `fail` does.
pub const Exit = struct { code: u8 = 0 };

/// What `fail` leaves of a failure. The defaults are what Zig does with an
/// error returned from `main`: `error: OutOfMemory` and status 1.
pub const Failure = struct {
    /// The status left in the `*Exit`, from 1 to 255.
    status: u8 = 1,
    /// What the line on stderr begins with: `"fatal"` writes
    /// `fatal: OutOfMemory`. With `null` nothing is written, and the
    /// handler does not ask for a `zrx.Stderr`.
    prefix: ?[]const u8 = "error",
};

/// A handler for the failure of a run: `rescue(cli.fail(.{}))`. It sets the
/// `*Exit` to `options.status` and writes one line that names the error to
/// `zrx.Stderr`, which the rescue is given for itself:
/// `rescue(cli.fail(.{})).provide(.{stderr(256)})`.
///
/// The status comes first and the line is best effort: a write that fails
/// is nobody's to take any more. A cancellation is a failure like any
/// other here and is reported as `Canceled`.
///
/// It is a handler of one error, so it also ends a pipe whose item is one:
/// `program(fromValue(err), .{forEach(cli.fail(.{}))})` says the same of
/// what failed before there was a run, such as a wrong argument.
pub fn fail(comptime options: Failure) type {
    if (options.status == 0) @compileError(
        "cli.fail: status 0 says the program succeeded, but this is what a failed run leaves; pass a status from 1 to 255, as in `cli.fail(.{ .status = 2 })`",
    );
    if (options.prefix) |prefix| if (prefix.len == 0) @compileError(
        "cli.fail: an empty prefix would begin the line with `: `; name what failed, as in `.prefix = \"fatal\"`, or write nothing with `.prefix = null`",
    );
    return struct {
        pub const zrx_handler = {};

        /// `fatal: {s}\n`, the prefix taken literally.
        const format: ?[]const u8 = if (options.prefix) |prefix| literal(prefix) ++ ": {s}\n" else null;

        pub fn requires(comptime _: usize) []const type {
            return if (format == null) &.{*Exit} else &.{ *Exit, Stderr };
        }

        pub fn call(env: anytype, args: anytype) void {
            if (comptime args.len != 1 or @typeInfo(@TypeOf(args[0])) != .error_set) @compileError(
                "cli.fail: is given one error, the failure of a run, but receives " ++ di.listTypes(di.types(@TypeOf(args))) ++
                    " here; bind it with `rescue(cli.fail(.{ ... }))`, or end a pipe whose item is an error with `forEach(cli.fail(.{ ... }))`",
            );
            di.get(env, *Exit).code = options.status;
            const line = format orelse return;
            const writer = di.get(env, Stderr).writer;
            writer.print(line, .{@errorName(args[0])}) catch return;
            writer.flush() catch {};
        }
    };
}

/// `text` as a format string that prints it: braces doubled.
fn literal(comptime text: []const u8) []const u8 {
    var out: []const u8 = "";
    for (text) |byte| out = out ++ switch (byte) {
        '{' => "{{",
        '}' => "}}",
        else => &[_]u8{byte},
    };
    return out;
}
