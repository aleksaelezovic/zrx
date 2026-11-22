//! The process a program runs in: its three standard streams and its exit
//! status.
//!
//!     pub fn main(init: std.process.Init) u8 {
//!         var exit: process.Exit = .{};
//!         app.run(.{
//!             init.io,
//!             &exit,
//!             process.stdin(Input, 4096),
//!             process.stdout(Stdout, 4096),
//!             rescue(process.fail(.{})).provide(.{process.stderr(Stderr, 256)}),
//!         });
//!         return exit.code;
//!     }
//!
//! Nothing here is known to the core: a stream is a binding like a file,
//! `Exit` a dependency like any other, `fail` and `status` handlers like
//! any other. Nothing here ends the process either: `main` returns the
//! status. Nothing allocates: a stream's buffer is a comptime size and
//! lives in its binding.
const std = @import("std");
const Io = std.Io;
const di = @import("../di.zig");
const io = @import("../io.zig");

// ---------------------------------------------------------------------------
// The standard streams
// ---------------------------------------------------------------------------

/// The role standard output is usually bound as: `stdout(Stdout, n)`.
pub const Stdout = io.Stdout;
/// The role standard error is usually bound as: `stderr(Stderr, n)`. It is
/// the one `fail` writes to.
pub const Stderr = io.Stderr;
/// The role standard input is usually bound as: `stdin(Stdin, n)`.
pub const Stdin = struct { reader: *Io.Reader };

/// Binds a reader of standard input as `Role` for the duration of a
/// program, for `lines(Role, n)` to read. With `lines`, `buffer_size` must
/// be at least the line limit plus one, for the newline.
///
/// It takes the place of a `fileReader(Role, path, n)`: a program over
/// `lines(Role, n)` is the same value for a file and for standard input,
/// and which it reads is the binding it is run with. A failed read fails
/// the run with `error.ReadFailed`, as with any reader given to `lines`.
///
/// The reader and its buffer are the binding's, and the reader reads ahead:
/// what it has read past where the pipe stopped is gone with it. Runs that
/// read on where the one before stopped share a reader `main` makes, given
/// to each as a value of the role.
pub fn stdin(comptime Role: type, comptime buffer_size: usize) Input(Role, buffer_size) {
    return .{};
}

/// Binds a writer to standard output as `Role` for the duration of a
/// program. It takes the place of a `fileWriter(Role, path, n, options)`.
/// Nothing is flushed here: `print` and `write` flush what they wrote.
pub fn stdout(comptime Role: type, comptime buffer_size: usize) Output(.stdout, Role, buffer_size) {
    return .{};
}

/// Binds a writer to standard error as `Role` for the duration of a
/// program, or of a rescue: `rescue(handler).provide(.{stderr(Stderr, 256)})`.
pub fn stderr(comptime Role: type, comptime buffer_size: usize) Output(.stderr, Role, buffer_size) {
    return .{};
}

fn Input(comptime Role: type, comptime buffer_size: usize) type {
    expectRole("stdin", Role, "reader", Io.Reader);
    return struct {
        pub const zrx_resource = {};
        pub const Provides = Role;
        pub const needs: []const type = &.{Io};

        pub fn bind(_: @This(), env: anytype, next: anytype) !void {
            var buffer: [buffer_size]u8 = undefined;
            var reader = Io.File.stdin().readerStreaming(di.get(env, Io), &buffer);
            return next.call(if (Role == *Io.Reader) &reader.interface else Role{ .reader = &reader.interface });
        }
    };
}

fn Output(comptime which: enum { stdout, stderr }, comptime Role: type, comptime buffer_size: usize) type {
    expectRole(@tagName(which), Role, "writer", Io.Writer);
    return struct {
        pub const zrx_resource = {};
        pub const Provides = Role;
        pub const needs: []const type = &.{Io};

        pub fn bind(_: @This(), env: anytype, next: anytype) !void {
            var buffer: [buffer_size]u8 = undefined;
            const file: Io.File = switch (which) {
                .stdout => .stdout(),
                .stderr => .stderr(),
            };
            var writer = file.writerStreaming(di.get(env, Io), &buffer);
            return next.call(if (Role == *Io.Writer) &writer.interface else Role{ .writer = &writer.interface });
        }
    };
}

/// A role is the type a stream is keyed by: the interface itself, or a
/// struct of the caller's with that one field.
fn expectRole(comptime which: []const u8, comptime Role: type, comptime field: []const u8, comptime Interface: type) void {
    if (Role == *Interface) return;
    const fits = @typeInfo(Role) == .@"struct" and
        @typeInfo(Role).@"struct".field_names.len == 1 and
        @hasField(Role, field) and
        @FieldType(Role, field) == *Interface;
    const interface = "*std." ++ @typeName(Interface);
    if (!fits) @compileError(
        "process." ++ which ++ ": is given `" ++ @typeName(Role) ++ "` as the role of the stream, which is not a " ++ field ++
            " role; pass `" ++ interface ++ "` or a struct with the single field `" ++ field ++ ": " ++ interface ++
            "`, such as `process." ++ [_]u8{std.ascii.toUpper(which[0])} ++ which[1..] ++ "`",
    );
}

// ---------------------------------------------------------------------------
// The exit status
// ---------------------------------------------------------------------------

/// How a program ended, for `main` to return. A run returns nothing, so the
/// status is an effect: `main` passes a `*Exit` to `run`, and whoever has
/// something to say about the outcome asks for it, as `status` and `fail` do.
pub const Exit = struct { code: u8 = 0 };

/// A handler that raises the status to at least `at_least` when it is
/// called, whatever it is called with: `tap(process.status(1))` on an error
/// path says that the program finished, and not with everything.
///
/// It never lowers a status, so it does not matter in which order two of
/// them are reached. It writes through the `*Exit` like any handler that
/// writes through a dependency: put it where one task calls it, after a
/// `concurrent` and not in its workers.
pub fn status(comptime at_least: u8) type {
    if (at_least == 0) @compileError(
        "process.status: status 0 raises nothing, since no status is below it; pass what an item that gets here leaves, from 1 to 255, as in `tap(process.status(1))`",
    );
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{*Exit};
        }

        pub fn call(env: anytype, args: anytype) void {
            if (comptime args.len == 1 and @typeInfo(@TypeOf(args[0])) == .error_set) @compileError(
                "process.status: is given an error alone here, `" ++ @typeName(@TypeOf(args[0])) ++
                    "`, and that is the failure of a run and not an item of one; the handler for it is `process.fail(.{ .status = " ++
                    std.fmt.comptimePrint("{d}", .{at_least}) ++ ", .prefix = null })`",
            );
            const exit = di.get(env, *Exit);
            exit.code = @max(exit.code, at_least);
        }
    };
}

/// What `fail` leaves of a failure. The defaults are what Zig does with an
/// error returned from `main`: `error: OutOfMemory` and status 1.
pub const Failure = struct {
    /// The status left in the `*Exit`, from 1 to 255.
    status: u8 = 1,
    /// What the line on stderr begins with: `"fatal"` writes
    /// `fatal: OutOfMemory`. With `null` nothing is written, and the
    /// handler does not ask for a `Stderr`.
    prefix: ?[]const u8 = "error",
};

/// A handler for the failure of a run: `rescue(process.fail(.{}))`. It sets
/// the `*Exit` to `options.status`, whatever a `status` left there, and
/// writes one line that names the error to `Stderr`, which the rescue is
/// given for itself:
/// `rescue(process.fail(.{})).provide(.{stderr(Stderr, 256)})`.
///
/// The name is written with `std.ascii.hexEscape`: a byte that is not
/// printable ASCII, such as a newline in a name declared in quotes, is
/// written as `\x0a`, so that the line stays one. An identifier is written
/// as it is.
///
/// The status comes first and the line is best effort: a write that fails
/// is nobody's to take any more. A cancellation is a failure like any
/// other here and is reported as `Canceled`.
///
/// It is a handler of one error, so it also ends a pipe whose item is one:
/// `program(fromValue(err), .{forEach(process.fail(.{}))})` says the same
/// of what failed before there was a run, such as a wrong argument.
pub fn fail(comptime options: Failure) type {
    if (options.status == 0) @compileError(
        "process.fail: status 0 says the program succeeded, but this is what a failed run leaves; pass a status from 1 to 255, as in `process.fail(.{ .status = 2 })`",
    );
    if (options.prefix) |prefix| {
        if (prefix.len == 0) @compileError(
            "process.fail: an empty prefix would begin the line with `: `; name what failed, as in `.prefix = \"fatal\"`, or write nothing with `.prefix = null`",
        );
        for (prefix, 0..) |byte, at| if (std.ascii.isControl(byte)) @compileError(std.fmt.comptimePrint(
            "process.fail: the prefix holds the control byte 0x{x:0>2} at index {d}, but what is written is one line of plain text: a newline would end it there, and another control byte can hide or overwrite it on a terminal; write the prefix without it, as in `.prefix = \"fatal\"`",
            .{ byte, at },
        ));
    }
    return struct {
        pub const zrx_handler = {};

        /// `fatal: {f}\n`, the prefix taken literally.
        const format: ?[]const u8 = if (options.prefix) |prefix| literal(prefix) ++ ": {f}\n" else null;

        pub fn requires(comptime _: usize) []const type {
            return if (format == null) &.{*Exit} else &.{ *Exit, Stderr };
        }

        pub fn call(env: anytype, args: anytype) void {
            if (comptime args.len != 1 or @typeInfo(@TypeOf(args[0])) != .error_set) @compileError(
                "process.fail: is given one error, the failure of a run, but receives " ++ di.listTypes(di.types(@TypeOf(args))) ++
                    " here; bind it with `rescue(process.fail(.{ ... }))`, or end a pipe whose item is an error with `forEach(process.fail(.{ ... }))`",
            );
            di.get(env, *Exit).code = options.status;
            const line = format orelse return;
            const writer = di.get(env, Stderr).writer;
            writer.print(line, .{std.ascii.hexEscape(@errorName(args[0]), .lower)}) catch return;
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
