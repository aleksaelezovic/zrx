const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

fn term(comptime self: type) type {
    return pattern.seq(.{ "<", pattern.oneOf(.{ pattern.extract(.inner, self), pattern.extract(.word, pattern.repeat(pattern.lower, .{ .min = 1 })) }), ">" });
}

fn toLine(text: []const u8) !zrx.Line(16) {
    return zrx.Line(16).from(text);
}

test {
    const texts = [_][]const u8{"<a>"};
    zrx.program(zrx.fromSlice(&texts), .{
        zrx.map(toLine),
        zrx.route(.{
            zrx.when(pattern.recursive(term, .{ .depth = 2 }), .{zrx.drain()}),
            zrx.otherwise(.{zrx.drain()}),
        }),
    }).run(.{zrx.rescue(ignore)});
}

fn ignore(_: anyerror) void {}
