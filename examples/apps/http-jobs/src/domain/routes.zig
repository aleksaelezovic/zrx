const std = @import("std");

/// Only the identifier grammar lives here; method/target selection is declared
/// in composition.zig. No query stripping, URL decoding or path normalization.
pub fn jobId(text: []const u8) error{InvalidId}!u64 {
    if (text.len == 0 or text[0] == '0') return error.InvalidId;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidId;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidId;
}

pub fn acceptsJson(content_type: ?[]const u8, encoded: bool) bool {
    return !encoded and std.ascii.eqlIgnoreCase(content_type orelse return false, "application/json");
}
