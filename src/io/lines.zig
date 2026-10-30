const std = @import("std");
const builtin = @import("builtin");
const records = @import("../data/lines.zig");
const sequences = @import("../data/sequences.zig");
const runtime = @import("../internal/runtime/streams.zig");
const resources = @import("../internal/resources.zig");
const execution = @import("../run.zig");
const SourceTag = opaque {};

fn requireHosted() void {
    if (builtin.os.tag == .freestanding)
        @compileError("line I/O requires a hosted target; Line values remain portable");
}

const Input = union(enum) {
    stdin,
    file: []const u8,
    tcp: std.Io.net.IpAddress,
};
const OutputConfig = union(enum) {
    stdout,
    stderr,
    file: struct { path: []const u8, options: std.Io.Dir.CreateFileOptions },
};

/// Declare LF-delimited stdin with bounded, inline Line(maxBytes) items.
/// Declaration does no I/O/allocation. run owns the reader/buffer but never
/// closes process stdin. EOF ends normally; blank lines are items; a nonempty
/// final unterminated record is emitted. CR/encoding are not normalized.
/// Exactly maxBytes bytes are accepted; an excess byte fails LineTooLong,
/// without forwarding that record. Failure discards unfinished payload.
/// Capacity must be positive at run time. Pointer identity shares execution;
/// two independent selected stdin declarations fail DuplicateIoEndpoint.
pub fn stdinLines(comptime maxBytes: usize, capacity: usize) Source(maxBytes) {
    comptime requireHosted();
    return .{ .input = .stdin, .capacity = capacity };
}

/// Declare a read-only file opened by run. Path bytes are borrowed/immutable
/// through run; relative paths use execution cwd. Each run opens afresh. The
/// owned handle closes only after workers join, including on failure/cancel.
/// Framing, bounds, and shallow-copy-safe records are as for stdinLines.
pub fn fileLines(path: []const u8, comptime maxBytes: usize, capacity: usize) Source(maxBytes) {
    comptime requireHosted();
    return .{ .input = .{ .file = path }, .capacity = capacity };
}

/// Declare an outgoing TCP byte stream to a standard IP/port value. run connects
/// once, owns/closes the socket, and frames LF records across arbitrary network
/// read boundaries. Peer EOF ends normally. No DNS, reconnect, listener,
/// application read timeout, half-close coordination, or full-duplex sharing.
pub fn tcpLines(address: std.Io.net.IpAddress, comptime maxBytes: usize, capacity: usize) Source(maxBytes) {
    comptime requireHosted();
    return .{ .input = .{ .tcp = address }, .capacity = capacity };
}

fn Source(comptime maxBytes: usize) type {
    return struct {
        pub const sequence_tag = sequences.SequenceTag;
        pub const graph_tag = sequences.GraphTag;
        pub const io_source_tag = SourceTag;
        pub const Item = records.Line(maxBytes);
        input: Input,
        capacity: usize,

        pub fn instantiate(self: @This(), scope: *resources.Scope) !runtime.Stream(Item) {
            const claim: ?resources.Claim = switch (self.input) {
                .stdin => .stdin,
                .file => |path| .{ .read_file = path },
                .tcp => null,
            };
            const slot = try scope.add(InputResource, .{ .input = self.input }, claim);
            const Producer = struct {
                fn produce(input: *InputResource, output: *runtime.Stream(Item)) !void {
                    while (true) {
                        const value = records.next(maxBytes, input.reader(), input.io) catch |err|
                            return if (err == error.ReadFailed) input.failure() else err;
                        try output.push(value orelse return);
                    }
                }
            };
            return runtime.Stream(Item).fromProducerWith(scope.allocator, scope.io, self.capacity, Producer.produce, slot);
        }
    };
}

pub fn isSource(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "io_source_tag") and T.io_source_tag == SourceTag;
}

const InputResource = struct {
    input: Input,
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

    fn reader(self: *@This()) *std.Io.Reader {
        return if (self.input == .tcp) &self.tcp_reader.interface else &self.file_reader.interface;
    }
    fn failure(self: *@This()) anyerror {
        return if (self.input == .tcp) self.tcp_reader.err orelse error.ReadFailed else self.file_reader.err orelse error.ReadFailed;
    }
    pub fn release(self: *@This(), io: std.Io) void {
        switch (self.input) {
            .stdin => {},
            .file => self.file.close(io),
            .tcp => self.connection.close(io),
        }
    }
};

/// Deferred Line(maxBytes) terminal. run owns writer/buffering, not the process
/// stdout handle. Writes payload + LF and flushes per record and on normal end.
/// Flush failure fails run; cleanup never silently flushes failed/canceled work.
/// Empty input writes no records. Duplicate selected stdout terminals fail
/// before acquisition: merge inputs into one terminal instead.
pub fn stdoutLines() Sink {
    comptime requireHosted();
    return .{ .output = .stdout };
}

/// As stdoutLines, using stderr independently. Relative stdout/stderr ordering
/// is unspecified; one selected terminal per process endpoint is supported.
pub fn stderrLines() Sink {
    comptime requireHosted();
    return .{ .output = .stderr };
}

/// Declare file output with explicit standard creation options. Path bytes stay
/// valid/immutable through run; relative paths use execution cwd. Acquisition
/// occurs even for empty input. Options can create/truncate immediately; later
/// failures leave those effects/partial output, not an atomic replacement.
/// run finishes output before success and closes after workers join on every
/// path. Flush is not fsync/durability. No implicit append or mkdir policy.
/// Equal textual input/output or duplicate output paths fail ConflictingIoPaths;
/// symlink/hardlink/relative aliases are NOT detected. Use distinct resources.
pub fn writeFileLines(path: []const u8, options: std.Io.Dir.CreateFileOptions) Sink {
    comptime requireHosted();
    return .{ .output = .{ .file = .{ .path = path, .options = options } } };
}

const Sink = struct {
    output: OutputConfig,

    pub fn Output(comptime SourceType: type) type {
        const Item = sequences.Item(SourceType);
        if (!records.isLine(Item)) @compileError("line output: expected Line(maxBytes) items");
        return execution.Flow(SourceType, Consumer(Item));
    }
    pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
        return .{ .source = source, .consumer = .{ .output = self.output } };
    }
};

fn Consumer(comptime Item: type) type {
    return struct {
        output: OutputConfig,
        slot: ?*OutputResource = null,

        pub fn prepare(_: *@This(), _: std.mem.Allocator) !void {}
        pub fn prepareResources(self: *@This(), scope: *resources.Scope) !void {
            const claim: resources.Claim = switch (self.output) {
                .stdout => .stdout,
                .stderr => .stderr,
                .file => |file| .{ .write_file = file.path },
            };
            self.slot = try scope.add(OutputResource, .{ .output = self.output }, claim);
        }
        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
        pub fn consume(self: @This(), reader: *runtime.Stream(Item).Reader, _: std.mem.Allocator, io: std.Io) !void {
            var input = reader.iterator();
            const slot = self.slot.?;
            while (true) {
                try io.checkCancel();
                const value = (try input.next()) orelse break;
                records.write(&slot.writer.interface, value) catch |err|
                    return if (err == error.WriteFailed) slot.writer.err orelse err else err;
            }
            try io.checkCancel();
            try slot.finish();
        }
    };
}

const OutputResource = struct {
    output: OutputConfig,
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
    fn finish(self: *@This()) !void {
        self.writer.interface.flush() catch |err| return self.writer.err orelse err;
    }
    pub fn release(self: *@This(), io: std.Io) void {
        if (self.output == .file) self.file.close(io);
    }
};
