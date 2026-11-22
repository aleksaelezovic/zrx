const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const drain = zrx.drain;
const json = zrx.ext.json;

test {
    const texts = [_][]const u8{"1"};
    program(fromSlice(&texts), .{ map(json.decode), drain() }).run(.{});
}
