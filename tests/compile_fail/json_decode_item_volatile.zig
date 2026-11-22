const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const drain = zrx.drain;
const json = zrx.ext.json;

const Entry = struct { id: u64 };
var bytes = "{\"id\":1}".*;
test {
    const texts = [_][]volatile u8{&bytes};
    program(fromSlice(&texts), .{ map(json.decode(Entry, .{ .scratch = 256 })), drain() }).run(.{});
}
