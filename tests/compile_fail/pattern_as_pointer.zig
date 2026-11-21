const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

/// Its `from` keeps the text it was given, which a line takes away with it.
const Borrowed = struct {
    text: []const u8,

    pub fn from(text: []const u8) Borrowed {
        return .{ .text = text };
    }
};

const named = pattern.extract(.name, pattern.as(Borrowed, pattern.repeat(pattern.lower, .{ .min = 1 })));

fn toLine(text: []const u8) !zrx.Line(16) {
    return zrx.Line(16).from(text);
}

test {
    const texts = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&texts), .{
        zrx.map(toLine),
        zrx.route(.{
            zrx.when(named, .{zrx.drain()}),
            zrx.otherwise(.{zrx.drain()}),
        }),
    }).run(.{zrx.rescue(ignore)});
}

fn ignore(_: anyerror) void {}
