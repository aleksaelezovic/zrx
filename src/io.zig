//! Basic byte and line I/O on top of `std.Io`.
//!
//! Writers and readers are ordinary dependencies. A *role* is the type they
//! are keyed by: `*std.Io.Writer` itself, or a struct with a single
//! `writer: *std.Io.Writer` field (`reader: *std.Io.Reader` for input) when a
//! program has more than one. Whoever owns a writer flushes it: the operators
//! below do so for the writers they create, and `main` does for the ones it
//! passes to `run`.
const std = @import("std");
const Io = std.Io;
const di = @import("di.zig");
const core = @import("pipe.zig");
const Flow = core.Flow;
const End = core.End;

/// The role provided by `stdout(n)`.
pub const Stdout = struct { writer: *Io.Writer };
/// The role provided by `stderr(n)`.
pub const Stderr = struct { writer: *Io.Writer };

fn isRole(comptime Role: type, comptime field_name: []const u8, comptime Interface: type) bool {
    if (Role == *Interface) return true;
    return @typeInfo(Role) == .@"struct" and @hasField(Role, field_name) and @FieldType(Role, field_name) == *Interface;
}

fn expectWriter(comptime who: []const u8, comptime Role: type) void {
    if (!isRole(Role, "writer", Io.Writer)) @compileError(
        who ++ ": `" ++ @typeName(Role) ++ "` is not a writer role; use `*std.Io.Writer` or a struct with a `writer: *std.Io.Writer` field",
    );
}

fn expectReader(comptime who: []const u8, comptime Role: type) void {
    if (!isRole(Role, "reader", Io.Reader)) @compileError(
        who ++ ": `" ++ @typeName(Role) ++ "` is not a reader role; use `*std.Io.Reader` or a struct with a `reader: *std.Io.Reader` field",
    );
}

fn expectProvided(comptime who: []const u8, comptime Env: type, comptime T: type) void {
    if (!di.has(Env, T)) @compileError(
        who ++ ": needs dependency `" ++ @typeName(T) ++ "`, which is not provided here; provided: " ++ di.listTypes(di.types(Env)),
    );
}

fn writerOf(role: anytype) *Io.Writer {
    return if (@TypeOf(role) == *Io.Writer) role else role.writer;
}

fn readerOf(role: anytype) *Io.Reader {
    return if (@TypeOf(role) == *Io.Reader) role else role.reader;
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

/// Ends the pipe by formatting every item to the writer keyed by `Role`:
/// `print(Stdout, "{d}\n")`. A tuple item supplies several format arguments.
pub fn print(comptime Role: type, comptime format: []const u8) Print(Role, format) {
    return .{};
}

fn Print(comptime Role: type, comptime format: []const u8) type {
    expectWriter("print", Role);
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "print";

        pub fn Out(comptime Env: type, comptime _: type) type {
            expectProvided(name, Env, Role);
            return End;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                writer: *Io.Writer,

                pub fn init(self: *@This(), _: *const Op, env: Env) !void {
                    self.writer = writerOf(di.get(env, Role));
                }

                pub fn push(self: *@This(), item: In, _: anytype) !Flow {
                    try self.writer.print(format, if (comptime di.isTuple(In)) item else .{item});
                    return .more;
                }
            };
        }
    };
}

/// Provides `Stdout`, a writer to standard output buffered by `buffer_size`
/// bytes. It is flushed when the stream ends (a failed flush fails the run)
/// and once more, best effort, when the program is torn down. Needs `std.Io`.
pub fn stdout(comptime buffer_size: usize) Standard(.stdout, buffer_size) {
    return .{};
}

/// Provides `Stderr`, a writer to standard error; see `stdout`.
pub fn stderr(comptime buffer_size: usize) Standard(.stderr, buffer_size) {
    return .{};
}

fn Standard(comptime which: enum { stdout, stderr }, comptime buffer_size: usize) type {
    const Role = switch (which) {
        .stdout => Stdout,
        .stderr => Stderr,
    };
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = @tagName(which);

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectProvided(name, Env, Io);
            return In;
        }

        pub fn Provides(comptime Env: type) type {
            return di.Extend(Env, Role);
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                buffer: [buffer_size]u8,
                out: Owned,

                pub fn init(self: *@This(), _: *const Op, env: Env) !void {
                    const io = di.get(env, Io);
                    const file: Io.File = switch (which) {
                        .stdout => .stdout(),
                        .stderr => .stderr(),
                    };
                    self.out = .init(io, file.writerStreaming(io, &.{}), &self.buffer);
                }

                pub fn provide(self: *@This(), env: Env) Provides(Env) {
                    return di.extend(env, Role{ .writer = &self.out.interface });
                }

                pub fn push(_: *@This(), item: In, down: anytype) !Flow {
                    return down.push(item);
                }

                pub fn flush(self: *@This()) !void {
                    return self.out.flush();
                }

                /// Whatever is written after `flush` (by a `release`, or before a
                /// failure) still goes out, on a best-effort basis.
                pub fn deinit(self: *@This()) void {
                    self.out.interface.flush() catch {};
                }
            };
        }
    };
}

pub const CreateFileOptions = struct {
    /// Fail with `error.PathAlreadyExists` instead of replacing an existing file.
    exclusive: bool = false,
};

/// Creates the file at `path` (replacing an existing one unless
/// `options.exclusive`) and provides a writer to it as `Role`, a struct with a
/// single `writer: *std.Io.Writer` field. The file is flushed when the stream
/// ends and closed afterwards. Needs `std.Io`.
pub fn createFile(
    comptime Role: type,
    path: []const u8,
    comptime buffer_size: usize,
    options: CreateFileOptions,
) CreateFile(Role, buffer_size) {
    return .{ .path = path, .options = options };
}

fn CreateFile(comptime Role: type, comptime buffer_size: usize) type {
    if (Role == *Io.Writer or !isRole(Role, "writer", Io.Writer) or @typeInfo(Role).@"struct".field_names.len != 1) @compileError(
        "createFile: `" ++ @typeName(Role) ++ "` must be a struct with a single `writer: *std.Io.Writer` field",
    );
    return struct {
        path: []const u8,
        options: CreateFileOptions,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "createFile";

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectProvided(name, Env, Io);
            return In;
        }

        pub fn Provides(comptime Env: type) type {
            return di.Extend(Env, Role);
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                io: Io,
                buffer: [buffer_size]u8,
                file: Io.File,
                out: Owned,

                pub fn init(self: *@This(), op: *const Op, env: Env) !void {
                    self.io = di.get(env, Io);
                    self.file = try Io.Dir.cwd().createFile(self.io, op.path, .{ .exclusive = op.options.exclusive });
                    self.out = .init(self.io, self.file.writer(self.io, &.{}), &self.buffer);
                }

                pub fn provide(self: *@This(), env: Env) Provides(Env) {
                    return di.extend(env, Role{ .writer = &self.out.interface });
                }

                pub fn push(_: *@This(), item: In, down: anytype) !Flow {
                    return down.push(item);
                }

                pub fn flush(self: *@This()) !void {
                    return self.out.flush();
                }

                pub fn deinit(self: *@This()) void {
                    self.out.interface.flush() catch {};
                    self.file.close(self.io);
                }
            };
        }
    };
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/// The lines of the reader keyed by `Role`, without their `\n`. A line is only
/// valid until the next one is read. A line and its `\n` must fit the reader's
/// buffer, so a buffer of `n + 1` bytes reads lines of up to `n`.
pub fn lines(comptime Role: type) Lines(Role) {
    return .{};
}

fn Lines(comptime Role: type) type {
    expectReader("lines", Role);
    return struct {
        pub const zrx_source = {};
        pub const Item = []const u8;

        pub fn run(_: *const @This(), env: anytype, down: anytype) !void {
            comptime expectProvided("lines", @TypeOf(env), Role);
            return pushLines(readerOf(di.get(env, Role)), down);
        }
    };
}

fn pushLines(reader: *Io.Reader, down: anytype) !void {
    while (try reader.takeDelimiter('\n')) |line| {
        if (try down.push(line) == .done) return;
    }
}

/// The lines of standard input. A line may be at most `max_line_bytes` long,
/// not counting its `\n`; a longer one fails the run with
/// `error.StreamTooLong`. Needs `std.Io`.
pub fn stdinLines(comptime max_line_bytes: usize) StdinLines(max_line_bytes) {
    return .{};
}

fn StdinLines(comptime max_line_bytes: usize) type {
    return struct {
        pub const zrx_source = {};
        pub const Item = []const u8;

        pub fn run(_: *const @This(), env: anytype, down: anytype) !void {
            comptime expectProvided("stdinLines", @TypeOf(env), Io);
            // Room for the longest line and the newline that ends it.
            var buffer: [max_line_bytes + 1]u8 = undefined;
            var reader = Io.File.stdin().readerStreaming(di.get(env, Io), &buffer);
            return pushLines(&reader.interface, down);
        }
    };
}

/// The lines of the file at `path`, opened when the program runs and closed
/// when it ends. A line may be at most `max_line_bytes` long, not counting
/// its `\n`; a longer one fails the run with `error.StreamTooLong`. Needs `std.Io`.
pub fn fileLines(path: []const u8, comptime max_line_bytes: usize) FileLines(max_line_bytes) {
    return .{ .path = path };
}

fn FileLines(comptime max_line_bytes: usize) type {
    return struct {
        path: []const u8,

        pub const zrx_source = {};
        pub const Item = []const u8;

        pub fn run(self: *const @This(), env: anytype, down: anytype) !void {
            comptime expectProvided("fileLines", @TypeOf(env), Io);
            const io = di.get(env, Io);
            const file = try Io.Dir.cwd().openFile(io, self.path, .{});
            defer file.close(io);
            // Room for the longest line and the newline that ends it.
            var buffer: [max_line_bytes + 1]u8 = undefined;
            var reader = file.reader(io, &buffer);
            return pushLines(&reader.interface, down);
        }
    };
}

/// The writer in front of a file this library owns: it holds the buffer and
/// passes what is written on to the file.
///
/// `std.Io.Writer` reports every failure as `error.WriteFailed`, a request to
/// cancel included, and by then the request has been used up: a `recover`
/// that takes the failed write for an item error would leave its task deaf
/// to being cancelled. So when a write fails because the task was asked to
/// cancel, the request is put back. The write still fails; the task's next
/// cancelation point answers `error.Canceled`.
const Owned = struct {
    io: Io,
    /// Unbuffered: `interface` holds the buffer.
    file: Io.File.Writer,
    interface: Io.Writer,
    /// The last write failed because the task was asked to cancel, and the
    /// request is pending again.
    interrupted: bool,

    fn init(io: Io, file: Io.File.Writer, buffer: []u8) Owned {
        return .{
            .io = io,
            .file = file,
            .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain } },
            .interrupted = false,
        };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const owned: *Owned = @alignCast(@fieldParentPtr("interface", w));
        owned.interrupted = false;
        const written = owned.file.interface.writeSplatHeader(w.buffered(), data, splat) catch |err| {
            if (owned.file.err) |cause| {
                if (cause == error.Canceled) {
                    // Not kept: a later failure with another cause must not
                    // be mistaken for this one.
                    owned.file.err = null;
                    owned.io.recancel();
                    owned.interrupted = true;
                }
            }
            return err;
        };
        if (written < w.end) {
            const rest = w.buffer[written..w.end];
            @memmove(w.buffer[0..rest.len], rest);
            w.end = rest.len;
            return 0;
        }
        const consumed = written - w.end;
        w.end = 0;
        return consumed;
    }

    /// A flush that fails because the task was asked to cancel is a
    /// cancellation, not a write error: the request that was put back is
    /// taken here.
    fn flush(owned: *Owned) (Io.Writer.Error || Io.Cancelable)!void {
        owned.interface.flush() catch |err| {
            if (owned.interrupted) try owned.io.checkCancel();
            return err;
        };
    }
};
