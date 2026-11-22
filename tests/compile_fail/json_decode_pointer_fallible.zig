const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const drain = zrx.drain;
const json = zrx.ext.json;

const Entry = struct {
    name: anyerror![]const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Entry {
        const read = try std.json.innerParse([]const u8, allocator, source, options);
        return .{ .name = try allocator.dupe(u8, read) };
    }
};
test {
    const texts = [_][]const u8{"\"rex\""};
    program(fromSlice(&texts), .{ map(json.decode(Entry, .{ .scratch = 256 })), drain() }).run(.{});
}
