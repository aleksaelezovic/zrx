const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

// Inside an `optional`, to hold that a part that may be absent is still looked at.
const named = pattern.seq(.{ pattern.optional(pattern.extract(.name, pattern.repeat(pattern.lower, .{ .min = 1 }))), "!" });

fn toLine(text: []const u8) !zrx.Line(16) {
    return zrx.Line(16).from(text);
}

test {
    const texts = [_][]const u8{"a!"};
    zrx.program(zrx.fromSlice(&texts), .{
        zrx.map(toLine),
        zrx.route(.{
            zrx.when(named, .{zrx.drain()}),
            zrx.otherwise(.{zrx.drain()}),
        }),
    }).run(.{zrx.rescue(ignore)});
}

fn ignore(_: anyerror) void {}
