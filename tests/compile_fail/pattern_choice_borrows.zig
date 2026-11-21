const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

const pair = pattern.seq(.{ pattern.extract(.key, pattern.repeat(pattern.lower, .{ .min = 1 })), "=", pattern.digit });
const either = pattern.extract(.value, pattern.oneOf(.{ .number = pattern.int(u32), .pair = pair }));

fn toLine(text: []const u8) !zrx.Line(16) {
    return zrx.Line(16).from(text);
}

test {
    const texts = [_][]const u8{"a=1"};
    zrx.program(zrx.fromSlice(&texts), .{
        zrx.map(toLine),
        zrx.route(.{
            zrx.when(either, .{zrx.drain()}),
            zrx.otherwise(.{zrx.drain()}),
        }),
    }).run(.{zrx.rescue(ignore)});
}

fn ignore(_: anyerror) void {}
