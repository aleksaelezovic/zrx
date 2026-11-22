//! Text in and out of a pipe, on top of `std.Io.Reader` and `std.Io.Writer`.
//!
//! Writers and readers are ordinary dependencies. A *role* is the type they
//! are keyed by: `*std.Io.Writer` itself, or a struct with a single
//! `writer: *std.Io.Writer` field (`reader: *std.Io.Reader` for input) when a
//! program has more than one. Print flushes the writer it uses.
//!
//! Nothing here opens anything: where a reader or a writer comes from is a
//! binding. The standard streams are `zrx.ext.process`'s and files are
//! `zrx.ext.fs`'s.
const std = @import("std");
const Io = std.Io;
const di = @import("di.zig");
const core = @import("pipe.zig");
const Flow = core.Flow;
const End = core.End;

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

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

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

        /// `std.json` reads a line like a byte slice, and what it read is
        /// copied: a string, or an array of numbers. A text of more bytes
        /// than a line holds is `error.LengthMismatch`, which is `std.json`'s.
        /// Read from text, as by `std.json.parseFromSlice`.
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const bytes = try std.json.innerParse([]const u8, allocator, source, options);
            return from(bytes) catch error.LengthMismatch;
        }

        /// The same, read from a `std.json.Value`, as by
        /// `std.json.parseFromValue`.
        pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const bytes = try std.json.innerParseFromValue([]const u8, allocator, source, options);
            return from(bytes) catch error.LengthMismatch;
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
