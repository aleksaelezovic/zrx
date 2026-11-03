//! Byte-oriented managed I/O and borrowed standard-reader/writer adapters.
const std = @import("std");
const builtin = @import("builtin");
const recipes = @import("../internal/world/resources.zig");
const sequences = @import("../data/sequences.zig");
const chunks = @import("../data/chunks.zig");
const effects = @import("../ops/effects.zig");
const callbacks = @import("../internal/callbacks.zig");
const declarations = @import("../data/declarations.zig");
const composition = @import("../internal/composition.zig");

fn requireHosted() void {
    if (builtin.os.tag == .freestanding) @compileError("byte I/O resources require a hosted target");
}

/// Stable byte-reader owner. Acquire once, never move/copy while acquired, and
/// release only after serial users stop/join. Stdin is borrowed; files and TCP
/// connections are owned. Configuration referents remain stable through run.
pub const Reader = struct {
    pub const Config = union(enum) { stdin, file: []const u8, tcp: std.Io.net.IpAddress };
    input: Config,
    io: std.Io = undefined,
    buffer: [4096]u8 = undefined,
    file: std.Io.File = undefined,
    connection: std.Io.net.Stream = undefined,
    file_reader: std.Io.File.Reader = undefined,
    tcp_reader: std.Io.net.Stream.Reader = undefined,

    pub fn acquire(self: *@This(), io: std.Io) !void {
        self.io = io;
        switch (self.input) {
            .stdin, .file => {
                self.file = if (self.input == .stdin) .stdin() else try std.Io.Dir.cwd().openFile(io, self.input.file, .{});
                self.file_reader = self.file.readerStreaming(io, &self.buffer);
            },
            .tcp => |address| {
                self.connection = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
                self.tcp_reader = self.connection.reader(io, &self.buffer);
            },
        }
    }

    /// Borrow the standard interface at its current position, without rewinding.
    pub fn interface(self: *@This()) *std.Io.Reader {
        return if (self.input == .tcp) &self.tcp_reader.interface else &self.file_reader.interface;
    }

    pub fn failure(self: *@This()) anyerror {
        return if (self.input == .tcp)
            self.tcp_reader.err orelse error.ReadFailed
        else
            self.file_reader.err orelse error.ReadFailed;
    }

    pub fn release(self: *@This(), io: std.Io) void {
        switch (self.input) {
            .stdin => {},
            .file => self.file.close(io),
            .tcp => self.connection.close(io),
        }
    }
};

/// Cold recipe providing *Reader. Allocates stable storage, opens afresh per run,
/// and releases after users join. Stdin keeps its process position. Like writer
/// recipes, arbitrary endpoints do not register graph endpoint/path claims.
/// Accepts configuration or a comptime-known typed provider returning Config or
/// E!Config. All provider parameters are injected services (no data suffix).
/// The provider runs once per acquisition, never during construction/per item.
/// Its borrowed referents must outlive reader use; errors remain acquisition
/// control. Provider dependencies stay alive until the reader is released.
pub fn reader(config: anytype) Configured(Reader.Config, if (@typeInfo(@TypeOf(config)) == .@"fn") config else {}, openReader, closeReader) {
    comptime requireHosted();
    return configured(Reader.Config, config, openReader, closeReader);
}

fn openReader(allocator: std.mem.Allocator, io: std.Io, config: Reader.Config) !*Reader {
    const value = try allocator.create(Reader);
    errdefer allocator.destroy(value);
    value.* = .{ .input = config };
    try value.acquire(io);
    return value;
}

fn closeReader(allocator: std.mem.Allocator, io: std.Io, value: *Reader) void {
    value.release(io);
    allocator.destroy(value);
}

/// Only explicit standard types (or the managed owner) are accepted. No custom
/// runtime reader registry/closure is needed; dispatch is selected at comptime.
fn requireReader(comptime T: type) void {
    if (T != *std.Io.Reader and T != *std.Io.File.Reader and T != *std.Io.net.Stream.Reader and T != *Reader)
        @compileError("reader input: expected mutable std.Io.Reader, std file/TCP reader or zrx.Reader pointer");
}

pub fn readerInterface(input: anytype) *std.Io.Reader {
    comptime requireReader(@TypeOf(input));
    const T = @TypeOf(input);
    if (T == *std.Io.Reader) return input;
    if (T == *std.Io.File.Reader or T == *std.Io.net.Stream.Reader) return &input.interface;
    if (T == *Reader) return input.interface();
    @compileError("reader input: expected mutable std.Io.Reader, std file/TCP reader or zrx.Reader pointer");
}

pub fn readerFailure(input: anytype) anyerror {
    if (comptime @TypeOf(input) == *std.Io.Reader) return error.ReadFailed;
    if (comptime @TypeOf(input) == *Reader) return input.failure();
    return input.err orelse error.ReadFailed;
}

/// Cold synchronous pull source, emitting owned nonempty Chunk(u8, capacity).
/// Reads up to capacity (not promised to fill it); chunk boundaries have no
/// framing meaning. No task/queue/prefetch is added. Reader and storage remain
/// stable, exclusive and borrowed through traversal. Read/cancel errors are
/// control failures, never pending operator errors. EOF emits no empty chunk.
pub fn readChunks(comptime capacity: usize, input: anytype) ReadSource(capacity, @TypeOf(input), true) {
    return .{ .input = input };
}

pub fn ReadSource(comptime capacity: usize, comptime Input: type, comptime chunked: bool) type {
    if (capacity == 0) @compileError("reader source: capacity must be positive");
    requireReader(Input);
    return struct {
        pub const graph_tag = sequences.GraphTag;
        pub const sequence_tag = sequences.SequenceTag;
        pub const node_kind = .reader;
        pub const is_chunked = chunked;
        pub const Item = if (chunked) chunks.Chunk(u8, capacity) else @import("../data/lines.zig").Line(capacity);
        pub const Requirements: [0]type = .{};
        input: Input,
    };
}

/// Stable byte-writer owner. write writes exactly the supplied bytes, without
/// framing or implicit flushing. flush is fallible successful finalization.
/// Release closes owned files without flushing failed work; stdio is borrowed.
/// Use serially; no locking/endpoint alias validation/fsync/rollback is implied.
pub const Writer = struct {
    pub const Config = union(enum) {
        stdout,
        stderr,
        file: struct { path: []const u8, options: std.Io.Dir.CreateFileOptions },
    };
    output: Config,
    file: std.Io.File = undefined,
    writer: std.Io.File.Writer = undefined,
    buffer: [4096]u8 = undefined,

    pub fn acquire(self: *@This(), io: std.Io) !void {
        self.file = switch (self.output) {
            .stdout => .stdout(),
            .stderr => .stderr(),
            .file => |file| try std.Io.Dir.cwd().createFile(io, file.path, file.options),
        };
        self.writer = self.file.writerStreaming(io, &self.buffer);
    }

    pub fn write(self: *@This(), data: []const u8) !void {
        try writeBytes(self, data);
    }

    pub fn flush(self: *@This()) !void {
        try flushOutput(self);
    }

    pub fn release(self: *@This(), io: std.Io) void {
        if (self.output == .file) self.file.close(io);
    }
};

/// Cold recipe providing *Writer. Buffer/handle live until users join. File
/// options explicitly choose creation policy. Recipes do not register endpoint
/// claims: callers ensure safe paths and serial/exclusive use across roles.
/// Accepts Config or a typed Config/E!Config provider, with the same injection,
/// coldness, lifetime and acquisition-error rules as reader.
pub fn writer(config: anytype) Configured(Writer.Config, if (@typeInfo(@TypeOf(config)) == .@"fn") config else {}, openWriter, closeWriter) {
    comptime requireHosted();
    return configured(Writer.Config, config, openWriter, closeWriter);
}

// Keep one acquisition/release implementation for static and injected config.
// This is recipe construction, not a per-item service or dynamic DI registry.
fn Configured(comptime Config: type, comptime config: anytype, comptime acquire_fn: anytype, comptime release_fn: anytype) type {
    const Base = @TypeOf(recipes.resource(@as(Config, undefined), acquire_fn, release_fn));
    if (@typeInfo(@TypeOf(config)) != .@"fn") return Base;
    const Meta = callbacks.Info(config, 0);
    if (composition.Payload(Meta.Return) != Config)
        @compileError("I/O configuration provider must return " ++ @typeName(Config) ++ " or E!" ++ @typeName(Config));
    return struct {
        pub const world_recipe_tag = recipes.RecipeTag;
        pub const Provided = Base.Provided;
        pub const AcquireServices = declarations.concat(&Base.AcquireServices, &Meta.Services);
        pub const ReleaseServices = Base.ReleaseServices;

        pub fn acquire(_: @This(), env: anytype) anyerror!Provided {
            const selected = callbacks.invoke(config, env, .{});
            const value = if (@typeInfo(Meta.Return) == .error_union) try selected else selected;
            return recipes.resource(value, acquire_fn, release_fn).acquire(env);
        }

        pub fn release(_: @This(), env: anytype, value: Provided) void {
            callbacks.invoke(release_fn, env, .{value});
        }
    };
}

fn configured(comptime Config: type, config: anytype, comptime acquire: anytype, comptime release: anytype) Configured(Config, if (@typeInfo(@TypeOf(config)) == .@"fn") config else {}, acquire, release) {
    if (comptime @typeInfo(@TypeOf(config)) == .@"fn") return .{};
    if (comptime @typeInfo(@TypeOf(config)) == .pointer and @typeInfo(@typeInfo(@TypeOf(config)).pointer.child) == .@"fn")
        @compileError("I/O configuration provider must be a comptime-known function, not a function pointer");
    return recipes.resource(configuration(Config, config), acquire, release);
}

// anytype preserves the public union-literal spelling as an anonymous struct.
// Restore its explicit destination type rather than weakening provider typing.
fn configuration(comptime Config: type, value: anytype) Config {
    const T = @TypeOf(value);
    if (T == Config) return value;
    if (comptime @typeInfo(Config) == .@"union" and @typeInfo(T) == .@"struct") {
        const fields = @typeInfo(T).@"struct".field_names;
        if (fields.len != 1 or !@hasField(Config, fields[0]))
            @compileError("I/O resource: expected configuration or a comptime-known configuration provider");
        return @unionInit(Config, fields[0], configuration(@FieldType(Config, fields[0]), @field(value, fields[0])));
    }
    if (comptime @typeInfo(Config) == .@"struct" and @typeInfo(T) == .@"struct") {
        const info = @typeInfo(Config).@"struct";
        inline for (@typeInfo(T).@"struct".field_names) |name| {
            if (!@hasField(Config, name)) @compileError("I/O configuration: unknown field " ++ name);
        }
        var result: Config = undefined;
        inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
            @field(result, name) = if (@hasField(T, name))
                configuration(Field, @field(value, name))
            else if (attrs.defaultValue(Field)) |default|
                default
            else
                @compileError("I/O configuration: missing field " ++ name);
        }
        return result;
    }
    return value;
}

fn openWriter(allocator: std.mem.Allocator, io: std.Io, config: Writer.Config) !*Writer {
    const value = try allocator.create(Writer);
    errdefer allocator.destroy(value);
    value.* = .{ .output = config };
    try value.acquire(io);
    return value;
}

fn closeWriter(allocator: std.mem.Allocator, io: std.Io, value: *Writer) void {
    value.release(io);
    allocator.destroy(value);
}

fn writerInterface(output: anytype) *std.Io.Writer {
    const T = @TypeOf(output);
    if (T == *std.Io.Writer) return output;
    if (T == *std.Io.File.Writer) return &output.interface;
    if (T == *Writer) return &output.writer.interface;
    @compileError("writer output: expected mutable std.Io.Writer, std file writer or zrx.Writer pointer");
}

fn writerFailure(output: anytype, err: anyerror) anyerror {
    if (comptime @TypeOf(output) == *std.Io.Writer) return err;
    if (comptime @TypeOf(output) == *Writer) return output.writer.err orelse err;
    return output.err orelse err;
}

/// Write exact bytes; no delimiter, flush or ownership transfer.
pub fn writeBytes(output: anytype, data: []const u8) !void {
    writerInterface(output).writeAll(data) catch |err| return writerFailure(output, err);
}

pub fn flushOutput(output: anytype) !void {
    writerInterface(output).flush() catch |err| return writerFailure(output, err);
}

/// Byte terminal: pass a borrowed writer pointer, or an exact pointer service
/// type (e.g. writeTo(*Writer)) to inject a run-owned/borrowed writer binding.
/// Consumes u8, byte arrays/slices/Chunks. Flushes only after normal end;
/// errors/cancellation suppress final flush. Does not itself close the writer.
pub fn writeTo(output: anytype) WriteTo(if (@TypeOf(output) == type) output else @TypeOf(output), @TypeOf(output) == type) {
    return .{ .output = if (comptime @TypeOf(output) == type) {} else output };
}

fn WriteTo(comptime OutputType: type, comptime injected: bool) type {
    if (OutputType != *std.Io.Writer and OutputType != *std.Io.File.Writer and OutputType != *Writer)
        @compileError("writer output: expected mutable std.Io.Writer, std file writer or zrx.Writer pointer");
    return struct {
        output: if (injected) void else OutputType,
        pub fn Output(comptime Source: type) type {
            const T = sequences.Item(Source);
            if (T != u8 and chunks.Element(T) != u8)
                @compileError("writeTo: expected byte or byte chunk items");
            return effects.Flow(Source, Consumer);
        }
        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source, .consumer = .{ .output = self.output } };
        }
        const Consumer = struct {
            pub const http_scoped_supported = false;
            pub const Services = if (injected) [_]type{OutputType} else [_]type{};
            output: if (injected) void else OutputType,
            pub fn prepare(_: *@This(), _: std.mem.Allocator) !void {}
            pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
            pub fn consume(self: @This(), source: anytype, env: anytype, _: std.mem.Allocator, io: std.Io) !void {
                const output = if (comptime injected) env.get(OutputType) else self.output;
                var cursor = source.iterator();
                while (true) {
                    try io.checkCancel();
                    var value = (try cursor.next()) orelse break;
                    if (comptime @TypeOf(value) == u8) {
                        try writeBytes(output, &.{value});
                    } else {
                        try writeBytes(output, chunks.slice(&value));
                    }
                }
                try io.checkCancel();
                try flushOutput(output);
            }
        };
    };
}
