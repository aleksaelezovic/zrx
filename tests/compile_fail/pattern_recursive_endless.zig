const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

fn group(comptime self: type) type {
    return pattern.seq(.{ "(", self, ")" });
}

test {
    _ = pattern.recursive(group, .{});
}
