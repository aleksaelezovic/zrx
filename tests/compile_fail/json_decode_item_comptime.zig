const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const drain = zrx.drain;
const json = zrx.ext.json;

const Entry = struct { id: u64 };
/// Reads its text only at compile time, which an item is not.
const Text = struct {
    bytes: []const u8,

    pub fn text(comptime self: *const Text) []const u8 {
        return self.bytes;
    }
};
test {
    const texts = [_]Text{.{ .bytes = "{\"id\":1}" }};
    program(fromSlice(&texts), .{ map(json.decode(Entry, .{ .scratch = 256 })), drain() }).run(.{});
}
