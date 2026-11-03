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

        /// Copy into this bounded type using the same rule as line(n, bytes).
        pub fn fromSlice(bytes: []const u8) error{LineTooLong}!@This() {
            return line(maxBytes, bytes);
        }

        /// Format into owned inline storage. Excess output fails without
        /// returning a truncated record; LF is not appended implicitly.
        pub fn fromFormat(comptime fmt: []const u8, args: anytype) error{LineTooLong}!@This() {
            var result: @This() = .{};
            const text = std.fmt.bufPrint(&result.bytes, fmt, args) catch return error.LineTooLong;
            result.len = text.len;
            return result;
        }
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

// Standard readers own framing/transport buffers. readSliceShort also supports
// unbuffered readers; framing and the line bound never depend on buffer size.
pub fn next(comptime maxBytes: usize, reader: *std.Io.Reader, io: std.Io) !?Line(maxBytes) {
    var state: @import("../internal/framing.zig").State(u8, .{ .max_items = maxBytes }) = .{};
    while (true) {
        try io.checkCancel();
        var one: [1]u8 = undefined;
        if (try reader.readSliceShort(&one) == 0) {
            var final = state.finish() orelse return null;
            return line(maxBytes, final.slice()) catch unreachable;
        }
        const byte = one[0];
        var item = (state.feed(byte, byte == '\n') catch return error.LineTooLong) orelse continue;
        return line(maxBytes, item.slice()) catch unreachable;
    }
}
