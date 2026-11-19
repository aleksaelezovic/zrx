//! Basic byte and line I/O on top of `std.Io`.
//!
//! Writers and readers are ordinary dependencies. A *role* is the type they
//! are keyed by: `*std.Io.Writer` itself, or a struct with a single
//! `writer: *std.Io.Writer` field (`reader: *std.Io.Reader` for input) when a
//! program has more than one. Print flushes the writer it uses.
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
/// Each item is flushed as it is printed; `write` flushes once, at the end.
pub fn print(comptime Role: type, comptime format: []const u8) Text("print", Role, format, .every_item) {
    return .{};
}

/// `print`, flushed only at the end of the stream: items stay in the
/// writer's buffer until it fills. For output nobody reads as it is produced.
pub fn write(comptime Role: type, comptime format: []const u8) Text("write", Role, format, .at_end) {
    return .{};
}

fn Text(comptime who: []const u8, comptime Role: type, comptime format: []const u8, comptime flush: enum { every_item, at_end }) type {
    expectWriter(who, Role);
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = who;

        pub fn Out(comptime Env: type, comptime _: type) type {
            expectProvided(name, Env, Role);
            return End;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                writer: *Io.Writer,

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.writer = writerOf(di.get(env, Role));
                }

                pub fn push(self: *@This(), item: In, _: anytype) !Flow {
                    try self.writer.print(format, if (comptime di.isTuple(In)) item else .{item});
                    if (flush == .every_item) try self.writer.flush();
                    return .more;
                }
                pub fn finish(self: *@This(), _: anytype) Io.Writer.Error!void {
                    try self.writer.flush();
                }
            };
        }
    };
}

/// Binds a standard-output writer for the duration of a program.
pub fn stdout(comptime buffer_size: usize) Standard(.stdout, buffer_size) {
    return .{};
}

/// Binds a standard-error writer for the duration of a program.
pub fn stderr(comptime buffer_size: usize) Standard(.stderr, buffer_size) {
    return .{};
}

fn Standard(comptime which: enum { stdout, stderr }, comptime buffer_size: usize) type {
    const Role = switch (which) {
        .stdout => Stdout,
        .stderr => Stderr,
    };
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
            return next.call(Role{ .writer = &writer.interface });
        }
    };
}

pub const FileMode = enum {
    /// Create the file, or empty it if it exists.
    replace,
    /// Create the file; `error.PathAlreadyExists` if something is there.
    create_new,
    /// Write to a temporary file in the same directory, and give it its name
    /// once everything this binding wraps has returned without an error and
    /// the writer is flushed. A failure before publication leaves the
    /// destination untouched. If the path already exists at publication,
    /// the run returns `error.PathAlreadyExists`. With several published
    /// files, the last one acquired is named first. Any files already published
    /// stay in place if a later publication fails.
    publish,
};

pub const FileWriterOptions = struct {
    mode: FileMode = .replace,
};

/// Creates a file and binds its writer for the duration of a program.
pub fn fileWriter(
    comptime Role: type,
    path: []const u8,
    comptime buffer_size: usize,
    options: FileWriterOptions,
) FileWriter(Role, buffer_size) {
    return .{ .path = path, .options = options };
}

fn FileWriter(comptime Role: type, comptime buffer_size: usize) type {
    expectWriter("fileWriter", Role);
    if (Role != *Io.Writer and @typeInfo(Role).@"struct".field_names.len != 1) @compileError(
        "fileWriter: use `*std.Io.Writer` or a role with a single `writer: *std.Io.Writer` field",
    );
    return struct {
        path: []const u8,
        options: FileWriterOptions,

        pub const zrx_resource = {};
        pub const Provides = Role;
        pub const needs: []const type = &.{Io};

        pub fn bind(self: @This(), env: anytype, next: anytype) !void {
            const io = di.get(env, Io);
            var buffer: [buffer_size]u8 = undefined;
            if (self.options.mode == .publish) {
                var pending = try Io.Dir.cwd().createFileAtomic(io, self.path, .{});
                defer pending.deinit(io);
                var writer = pending.file.writer(io, &buffer);
                try next.call(roleOf(&writer.interface));
                try writer.interface.flush();
                return pending.link(io);
            }
            const file = try Io.Dir.cwd().createFile(io, self.path, .{ .exclusive = self.options.mode == .create_new });
            defer file.close(io);
            var writer = file.writer(io, &buffer);
            return next.call(roleOf(&writer.interface));
        }

        fn roleOf(writer: *Io.Writer) Role {
            return if (Role == *Io.Writer) writer else .{ .writer = writer };
        }
    };
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/// Opens the file at `path` and binds its reader as `Role` for the duration
/// of a program, for `lines(Role, n)` to read. With `lines`, `buffer_size`
/// must be at least the line limit plus one, for the newline.
///
/// A program over `lines(Role, n)` is the same value whether its reader is a
/// file (this binding) or one a test supplies in its place.
pub fn fileReader(comptime Role: type, path: []const u8, comptime buffer_size: usize) FileReader(Role, buffer_size) {
    return .{ .path = path };
}

fn FileReader(comptime Role: type, comptime buffer_size: usize) type {
    expectReader("fileReader", Role);
    if (Role != *Io.Reader and @typeInfo(Role).@"struct".field_names.len != 1) @compileError(
        "fileReader: use `*std.Io.Reader` or a role with a single `reader: *std.Io.Reader` field",
    );
    return struct {
        path: []const u8,

        pub const zrx_resource = {};
        pub const Provides = Role;
        pub const needs: []const type = &.{Io};

        pub fn bind(self: @This(), env: anytype, next: anytype) !void {
            const io = di.get(env, Io);
            const file = try Io.Dir.cwd().openFile(io, self.path, .{});
            defer file.close(io);
            var buffer: [buffer_size]u8 = undefined;
            var reader = file.reader(io, &buffer);
            return next.call(if (Role == *Io.Reader) &reader.interface else Role{ .reader = &reader.interface });
        }
    };
}

/// A line with its bytes stored inline, without the newline. Also serves as
/// owned text of bounded length: `Line(32).from(name)`.
pub fn Line(comptime max_line_bytes: usize) type {
    return struct {
        bytes: [max_line_bytes]u8,
        len: usize,

        /// A line holding a copy of `bytes`; `error.StreamTooLong` if there are too many.
        pub fn from(bytes: []const u8) error{StreamTooLong}!@This() {
            if (bytes.len > max_line_bytes) return error.StreamTooLong;
            var line: @This() = .{ .bytes = undefined, .len = bytes.len };
            @memcpy(line.bytes[0..line.len], bytes);
            return line;
        }

        pub fn text(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn format(self: @This(), writer: *Io.Writer) Io.Writer.Error!void {
            try writer.writeAll(self.text());
        }

        /// `std.json` formats a line like a byte slice. By default, valid
        /// UTF-8 becomes a JSON string and invalid UTF-8 becomes an array
        /// of numbers. `emit_strings_as_arrays` uses arrays for both.
        pub fn jsonStringify(self: *const @This(), json: anytype) !void {
            try json.write(self.text());
        }
    };
}

/// The lines of the reader keyed by `Role`. The reader buffer must have
/// room for `max_line_bytes + 1` bytes to accept a maximum-length line and its newline.
/// On `error.StreamTooLong`, the reader stays at the start of the rejected line.
pub fn lines(comptime Role: type, comptime max_line_bytes: usize) Lines(Role, max_line_bytes) {
    return .{};
}

fn Lines(comptime Role: type, comptime max_line_bytes: usize) type {
    expectReader("lines", Role);
    return struct {
        pub const zrx_source = {};
        pub const Item = Line(max_line_bytes);

        pub fn run(_: *const @This(), env: anytype, down: anytype) !void {
            comptime expectProvided("lines", @TypeOf(env), Role);
            return pushLines(max_line_bytes, readerOf(di.get(env, Role)), down);
        }
    };
}

fn pushLines(comptime max_line_bytes: usize, reader: *Io.Reader, down: anytype) !void {
    while (true) {
        const buffered_line = reader.peekDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => reader.buffered(),
            else => |e| return e,
        };
        if (buffered_line.len == 0) return;
        const text = if (buffered_line[buffered_line.len - 1] == '\n')
            buffered_line[0 .. buffered_line.len - 1]
        else
            buffered_line;
        const line: Line(max_line_bytes) = try .from(text);
        reader.toss(buffered_line.len);
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
        pub const Item = Line(max_line_bytes);

        pub fn run(_: *const @This(), env: anytype, down: anytype) !void {
            comptime expectProvided("stdinLines", @TypeOf(env), Io);
            // Room for the longest line and the newline that ends it.
            var buffer: [max_line_bytes + 1]u8 = undefined;
            var reader = Io.File.stdin().readerStreaming(di.get(env, Io), &buffer);
            return pushLines(max_line_bytes, &reader.interface, down);
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
        pub const Item = Line(max_line_bytes);

        pub fn run(self: *const @This(), env: anytype, down: anytype) !void {
            comptime expectProvided("fileLines", @TypeOf(env), Io);
            const io = di.get(env, Io);
            const file = try Io.Dir.cwd().openFile(io, self.path, .{});
            defer file.close(io);
            // Room for the longest line and the newline that ends it.
            var buffer: [max_line_bytes + 1]u8 = undefined;
            var reader = file.reader(io, &buffer);
            return pushLines(max_line_bytes, &reader.interface, down);
        }
    };
}
