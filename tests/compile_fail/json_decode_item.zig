const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const drain = zrx.drain;
const json = zrx.ext.json;

const Entry = struct { id: u64 };
test {
    const texts = [_]u32{1};
    program(fromSlice(&texts), .{ map(json.decode(Entry, .{ .scratch = 256 })), drain() }).run(.{});
}
