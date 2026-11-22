//! Compressed input and output as bindings, on top of `std.compress`.
//!
//!     const Input = struct { reader: *std.Io.Reader }; // what the pipe reads
//!     const Packed = struct { reader: *std.Io.Reader }; // the compressed bytes
//!
//!     const app = program(lines(Input, max_line), work);
//!
//!     app.run(.{ io, fileReader(Input, "access.log", max_line + 1) });
//!     app.run(.{
//!         io,
//!         fileReader(Packed, "access.log.gz", 4096),
//!         compress.gzipReader(Input, Packed, max_line + 1),
//!     });
//!
//! Nothing here is known to the core, and nothing of it is in a pipe: each
//! of these is a resource that needs one role and provides another, and the
//! order of acquisition follows from that. The codecs are `std`'s; what is
//! added is a buffer in front of a decoder, the checks of a header that
//! `std` reads past, the check of a checksum `std` reads and does not
//! compare, and the end of a compressed stream once what the binding wraps
//! has succeeded.
const std = @import("std");
const Io = std.Io;
const di = @import("../di.zig");
const flate = std.compress.flate;
const zstd = std.compress.zstd;

// ---------------------------------------------------------------------------
// Roles
// ---------------------------------------------------------------------------

const Side = struct {
    field: []const u8,
    Interface: type,
    interface: []const u8,
    does: []const u8,
};

const reading: Side = .{ .field = "reader", .Interface = Io.Reader, .interface = "std.Io.Reader", .does = "reads the compressed bytes from" };
const writing: Side = .{ .field = "writer", .Interface = Io.Writer, .interface = "std.Io.Writer", .does = "writes the compressed bytes to" };

fn isRole(comptime side: Side, comptime Role: type) bool {
    if (Role == *side.Interface) return true;
    return @typeInfo(Role) == .@"struct" and @hasField(Role, side.field) and @FieldType(Role, side.field) == *side.Interface;
}

/// `Role` is what the binding provides and `Other` what it needs: two roles
/// of one kind, and not the same one.
fn expectRoles(comptime who: []const u8, comptime side: Side, comptime Role: type, comptime Other: type) void {
    const shape = "`*" ++ side.interface ++ "` or a struct with a `" ++ side.field ++ ": *" ++ side.interface ++ "` field";
    for ([_]type{ Role, Other }) |R| if (!isRole(side, R)) @compileError(
        who ++ ": `" ++ @typeName(R) ++ "` is not a " ++ side.field ++ " role; use " ++ shape,
    );
    if (Role != *side.Interface and @typeInfo(Role).@"struct".field_names.len != 1) @compileError(
        who ++ ": it makes the `" ++ @typeName(Role) ++ "` it provides, so that must be `*" ++ side.interface ++ "` or a role with a single `" ++ side.field ++ ": *" ++ side.interface ++ "` field",
    );
    if (Role == Other) @compileError(
        who ++ ": `" ++ @typeName(Role) ++ "` is given as the role it provides and as the role it " ++ side.does ++
            ", but a type has one provider; give the compressed bytes a role of their own, such as `const Packed = struct { " ++
            side.field ++ ": *" ++ side.interface ++ " };`",
    );
}

fn interfaceOf(comptime side: Side, role: anytype) *side.Interface {
    return if (@TypeOf(role) == *side.Interface) role else @field(role, side.field);
}

fn roleOf(comptime side: Side, comptime Role: type, interface: *side.Interface) Role {
    if (Role == *side.Interface) return interface;
    var role: Role = undefined;
    @field(role, side.field) = interface;
    return role;
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/// Binds as `Role` a reader of the plain bytes of the gzip stream that the
/// reader keyed by `From` holds: what a program reads with `lines(Role, n)`
/// is then a gzip file by this binding alone. `buffer_size` is what it is
/// for `fileReader`: with `lines`, at least the line limit plus one.
///
/// Every member of the stream is read, one after another. Each one's header
/// is checked before it is decoded, and its checksum and length are compared
/// with what it declares once it has been read to its end. A stream that is
/// cut short, corrupt, or followed by bytes that are no member fails the
/// read, and with it the run, with `error.ReadFailed`.
///
/// Costs the 64 KiB window of the format and 4 KiB for compressed bytes
/// beside the buffer, held while the program runs. The reader keyed by
/// `From` may have any buffer, or none.
pub fn gzipReader(comptime Role: type, comptime From: type, comptime buffer_size: usize) FlateReader(.gzip, Role, From, buffer_size) {
    return .{};
}

/// `gzipReader` for a zlib stream (RFC 1950). Its header is checked, and
/// one that asks for a preset dictionary fails the read: there is none to
/// give. Its checksum is compared once it has been read to its end.
///
/// There is one stream, and what follows it is not read. Once the stream has
/// been read to its end, what follows is still in the reader keyed by `From`
/// if that reader has a buffer of 4 bytes or more. One with less is read 4
/// KiB at a time, and what was read past the end of the stream is gone.
pub fn zlibReader(comptime Role: type, comptime From: type, comptime buffer_size: usize) FlateReader(.zlib, Role, From, buffer_size) {
    return .{};
}

/// How many compressed bytes a reading binding holds itself where the
/// reader it was given cannot hold what a decoder asks of its input. `std`'s
/// decoders assert that their input can hold what they look at before they
/// take it, and a reader bound by someone else may hold less, or nothing.
const held_bytes = 4096;

/// The most `std`'s flate decoder asks its input to hold: it looks at four
/// bytes and takes what it used of them. A header is read into memory of
/// the decoder's own, and `begin` looks at no more than four bytes of it.
const flate_ahead = 4;

fn FlateReader(comptime container: flate.Container, comptime Role: type, comptime From: type, comptime buffer_size: usize) type {
    expectRoles(@tagName(container) ++ "Reader", reading, Role, From);
    return struct {
        pub const zrx_resource = {};
        pub const Provides = Role;
        pub const needs: []const type = &.{From};

        pub fn bind(_: @This(), env: anytype, next: anytype) !void {
            // The decoder takes from its input the bytes of the stream and
            // no more, so it reads the caller's reader itself: what follows
            // a zlib stream is then still in that reader. One that cannot
            // hold what the decoder looks at is read through `held`, which
            // takes from it whatever fits, past the end of the stream too.
            const from = interfaceOf(reading, di.get(env, From));
            var held: [held_bytes]u8 = undefined;
            var ahead = from.limited(.unlimited, &held);
            const compressed = if (from.buffer.len >= flate_ahead) from else &ahead.interface;
            var window: [flate.max_window_len]u8 = undefined;
            var buffer: [buffer_size]u8 = undefined;
            var plain: Plain(Inflate(container)) = .init(.{ .decoder = .init(compressed, container, &window) }, &buffer);
            return next.call(roleOf(reading, Role, &plain.reader));
        }
    };
}

/// Binds as `Role` a reader of the plain bytes of the Zstandard stream that
/// the reader keyed by `From` holds, as `gzipReader` does for gzip. Frames
/// are read one after another, and skippable frames are skipped.
///
/// `window` is the decoder's memory, and the caller's: nothing is
/// allocated. It holds one block, `std.compress.zstd.block_size_max` (128
/// KiB), and in what is left the window: the largest a frame may ask for.
/// What the format recommends every decoder to accept is
/// `std.compress.zstd.default_window_len`, 8 MiB; `zstd --long` writes
/// frames that need more. A slice with no room for a window fails the run
/// with `error.ZstdWindowTooSmall` before anything is read. It is the
/// binding's while a program runs: two runs at one time need two.
///
/// Beside it the binding holds 4 KiB of compressed bytes, and `std`'s
/// decoder keeps two blocks, 256 KiB, on the stack of the task that reads.
///
/// A stream that is cut short or corrupt fails the read with
/// `error.ReadFailed`, and so does a frame that needs a larger window or a
/// dictionary. The checksum of a frame's content is not compared: `std`
/// does not do it yet.
pub fn zstdReader(comptime Role: type, comptime From: type, comptime buffer_size: usize, window: []u8) ZstdReader(Role, From, buffer_size) {
    return .{ .window = window };
}

fn ZstdReader(comptime Role: type, comptime From: type, comptime buffer_size: usize) type {
    expectRoles("zstdReader", reading, Role, From);
    return struct {
        window: []u8,

        pub const zrx_resource = {};
        pub const Provides = Role;
        pub const needs: []const type = &.{From};

        pub fn bind(self: @This(), env: anytype, next: anytype) !void {
            // `std` asserts that a block fits beside the window it is told.
            if (self.window.len <= zstd.block_size_max) return error.ZstdWindowTooSmall;
            const window_len = std.math.cast(u32, self.window.len - zstd.block_size_max) orelse std.math.maxInt(u32);
            // The decoder looks at 2048 bytes of a table before it takes
            // them, which is more than to ask of a caller's reader. It
            // reads to the end of its input, so nothing is taken from that
            // reader that a successful read would have left in it.
            var held: [held_bytes]u8 = undefined;
            var compressed = interfaceOf(reading, di.get(env, From)).limited(.unlimited, &held);
            var buffer: [buffer_size]u8 = undefined;
            var plain: Plain(Unzstd) = .init(.{ .decoder = .init(&compressed.interface, self.window, .{ .window_len = window_len }) }, &buffer);
            return next.call(roleOf(reading, Role, &plain.reader));
        }
    };
}

/// The reader a program is given: a buffer of its own in front of a `std`
/// decoder, which keeps its window to itself.
///
/// The decoder's reader is not handed out as it is. Its buffer is its
/// window, and it asserts that nobody asks it to hold more than that leaves
/// room for: `lines` looking for the end of a long line in a flate stream
/// was a panic in a safe build. Behind a buffer of its own such a line is
/// `error.StreamTooLong`, as it is for a file. It costs one copy of the
/// plain bytes, from the window to the buffer.
///
/// Every byte handed on passes through here, which is where a codec counts
/// them (`passed`), where it checks what `std` does not of a header before
/// the decoder takes it (`begin`), and where it says what the end of the
/// decoder's stream means (`ended`): the end, a failure, or more to come.
fn Plain(comptime Codec: type) type {
    return struct {
        codec: Codec,
        reader: Io.Reader,
        /// A decoder that failed is not asked again: `std` leaves its state
        /// where it stood, and what it would make of the rest is unknown.
        failed: bool = false,

        const Self = @This();

        fn init(codec: Codec, buffer: []u8) Self {
            return .{ .codec = codec, .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            } };
        }

        fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            const self: *Self = @alignCast(@fieldParentPtr("reader", r));
            const decoded = &self.codec.decoder.reader;
            const ready = decoded.buffered();
            if (ready.len != 0) {
                const n = try w.write(limit.slice(ready));
                self.codec.passed(ready[0..n]);
                decoded.toss(n);
                return n;
            }
            if (self.failed) return error.ReadFailed;
            self.codec.begin() catch return self.fail();
            // Nothing is buffered, so this asks the decoder for room for one
            // byte, which its window always has.
            decoded.fillMore() catch |err| switch (err) {
                error.ReadFailed => return self.fail(),
                error.EndOfStream => self.codec.ended() catch |end| switch (end) {
                    error.ReadFailed => return self.fail(),
                    error.EndOfStream => return error.EndOfStream,
                },
            };
            return 0;
        }

        /// What the decoder made of the bytes before the one it failed at
        /// is in its buffer and is handed on first: a stream that was cut
        /// short gives what it has, and then fails.
        fn fail(self: *Self) error{ReadFailed}!usize {
            self.failed = true;
            return if (self.codec.decoder.reader.bufferedLen() == 0) error.ReadFailed else 0;
        }
    };
}

fn Inflate(comptime container: flate.Container) type {
    return struct {
        decoder: flate.Decompress,
        sum: flate.Container.Hasher = .init(container),

        fn passed(self: *@This(), bytes: []const u8) void {
            self.sum.update(bytes);
        }

        /// `std` checks the magic number and the method of a header, and
        /// reads the rest as it comes. What the RFCs say a decoder must
        /// refuse besides is refused here, while the decoder has taken none
        /// of it: a reserved gzip flag, which may mean a field `std` would
        /// read as data (RFC 1952), and a zlib header whose check bits are
        /// wrong, or that asks for a preset dictionary (RFC 1950).
        fn begin(self: *@This()) Io.Reader.Error!void {
            if (self.decoder.state != .protocol_header) return;
            const in = self.decoder.input;
            switch (container) {
                .gzip => {
                    const reserved: u8 = 0b1110_0000;
                    if ((try in.peekArray(4))[3] & reserved != 0) return error.ReadFailed;
                },
                .zlib => {
                    const header = try in.peekArray(2);
                    const dictionary: u8 = 0b0010_0000;
                    if (std.mem.readInt(u16, header, .big) % 31 != 0) return error.ReadFailed;
                    if (header[1] & dictionary != 0) return error.ReadFailed;
                },
                .raw => comptime unreachable,
            }
        }

        /// The decoder has read a whole stream and its trailer. `std` keeps
        /// what the trailer declares and compares nothing; that is done
        /// here. Returning means there is more to read.
        fn ended(self: *@This()) Io.Reader.Error!void {
            switch (container) {
                .gzip => {
                    const declared = self.decoder.container_metadata.gzip;
                    if (declared.crc != self.sum.gzip.crc.final()) return error.ReadFailed;
                    if (declared.count != self.sum.gzip.count) return error.ReadFailed;
                    // A gzip file is a series of members (RFC 1952): while
                    // bytes follow, they are the next one.
                    const from = self.decoder.input;
                    const window = self.decoder.reader.buffer;
                    _ = try from.peekByte();
                    self.* = .{ .decoder = .init(from, container, window) };
                },
                .zlib => {
                    if (self.decoder.container_metadata.zlib.adler != self.sum.zlib.adler) return error.ReadFailed;
                    return error.EndOfStream;
                },
                .raw => comptime unreachable,
            }
        }
    };
}

const Unzstd = struct {
    decoder: zstd.Decompress,

    fn passed(_: *Unzstd, _: []const u8) void {}

    fn begin(_: *Unzstd) Io.Reader.Error!void {}

    /// `std` goes from frame to frame itself: its end is the end.
    fn ended(_: *Unzstd) Io.Reader.Error!void {
        return error.EndOfStream;
    }
};

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

pub const WriterOptions = struct {
    /// How hard to look for repetitions: `.fastest`, `.default`, `.best`,
    /// or one of `std`'s `.level_1` to `.level_9`.
    level: flate.Compress.Options = .default,
};

/// Binds as `Role` a writer whose bytes reach the writer keyed by `Into` as
/// a gzip stream: what a program writes with `write(Role, "fmt")` is then
/// compressed by this binding alone.
///
/// The stream is given its end, with checksum and length, once everything
/// the binding wraps has returned without an error, and `Into` is flushed
/// then. That can fail, which a release cannot, so it is part of the run:
/// the run fails with `error.WriteFailed`. When what the binding wraps
/// fails, the stream is left without its end, and reading it back fails. A
/// failure after that, in writing the end or in another binding, may leave
/// the whole stream behind. Under a `fileWriter` in `.publish` mode the end
/// is written before the file is named.
///
/// A flush of `Role` ends a block and does not reach `Into`, so `print`,
/// which flushes every item, costs compression and shows nobody the item:
/// use `write`.
///
/// Costs the 64 KiB window of the format and 225 KiB of `std`'s compressor,
/// held while the program runs. The writer keyed by `Into` needs a buffer
/// of 9 bytes or more; with less, the run fails with
/// `error.CompressedBufferTooSmall` before anything is written.
pub fn gzipWriter(comptime Role: type, comptime Into: type, options: WriterOptions) FlateWriter(.gzip, Role, Into) {
    return .{ .options = options };
}

/// `gzipWriter` for a zlib stream (RFC 1950).
pub fn zlibWriter(comptime Role: type, comptime Into: type, options: WriterOptions) FlateWriter(.zlib, Role, Into) {
    return .{ .options = options };
}

fn FlateWriter(comptime container: flate.Container, comptime Role: type, comptime Into: type) type {
    expectRoles(@tagName(container) ++ "Writer", writing, Role, Into);
    return struct {
        options: WriterOptions,

        pub const zrx_resource = {};
        pub const Provides = Role;
        pub const needs: []const type = &.{Into};

        pub fn bind(self: @This(), env: anytype, next: anytype) !void {
            const into = interfaceOf(writing, di.get(env, Into));
            // `std` asserts this, which is no answer in a release build.
            if (into.buffer.len <= 8) return error.CompressedBufferTooSmall;
            // The compressor's buffer is its window: there is none to size.
            var window: [flate.max_window_len]u8 = undefined;
            var packer: flate.Compress = try .init(into, &window, container, self.options.level);
            try next.call(roleOf(writing, Role, &packer.writer));
            try packer.finish();
            return into.flush();
        }
    };
}
