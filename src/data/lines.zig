const std = @import("std");
const Tag = opaque {};

/// A shallow-copy-safe byte record with inline storage. maxBytes must be a
/// positive comptime bound. Only bytes[0..len] are payload; input adapters strip
/// their LF delimiters. CR, NUL, and invalid UTF-8 remain ordinary bytes.
/// Callers must keep len <= maxBytes; line output rejects invalid lengths.
/// Do not return a slice into a temporary record from an element transform.
pub fn Line(comptime maxBytes: usize) type {
    if (maxBytes == 0) @compileError("Line: maxBytes must be positive");
    return struct {
        pub const line_tag = Tag;
        pub const max_bytes = maxBytes;
        bytes: [maxBytes]u8 = @splat(0),
        len: usize = 0,
    };
}

/// Copy bytes into a value-owned line without allocation or implicit encoding.
/// Oversized input fails; this does not strip or append a delimiter.
pub fn line(comptime maxBytes: usize, bytes: []const u8) error{LineTooLong}!Line(maxBytes) {
    if (bytes.len > maxBytes) return error.LineTooLong;
    var result: Line(maxBytes) = .{};
    @memcpy(result.bytes[0..bytes.len], bytes);
    result.len = bytes.len;
    return result;
}

pub fn isLine(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "line_tag") and
        T.line_tag == Tag and T == Line(T.max_bytes);
}

// Standard readers own framing/transport buffers. Copy payload byte-by-byte
// from their already-buffered interface; no buffer-size-dependent line limit.
pub fn next(comptime maxBytes: usize, reader: *std.Io.Reader, io: std.Io) !?Line(maxBytes) {
    var result: Line(maxBytes) = .{};
    while (true) {
        try io.checkCancel();
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return if (result.len == 0) null else result,
            else => return err,
        };
        if (byte == '\n') return result;
        if (result.len == maxBytes) return error.LineTooLong;
        result.bytes[result.len] = byte;
        result.len += 1;
    }
}

pub fn write(writer: *std.Io.Writer, value: anytype) !void {
    if (comptime !isLine(@TypeOf(value))) @compileError("line output: expected Line(maxBytes) items");
    if (value.len > value.bytes.len) return error.InvalidLineLength;
    try writer.writeAll(value.bytes[0..value.len]);
    try writer.writeByte('\n');
    try writer.flush();
}
