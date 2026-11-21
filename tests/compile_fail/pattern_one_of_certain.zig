const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

/// Its `from` cannot fail, so the first choice does always match.
const Length = struct {
    bytes: usize,

    pub fn from(text: []const u8) Length {
        return .{ .bytes = text.len };
    }
};

test {
    _ = pattern.oneOf(.{ pattern.as(Length, pattern.optional("x")), "x" });
}
