//! A handler error fails the run unless a `recover` before it takes it. Here
//! good records go to stdout and rejected ones down a path of their own.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const recover = zrx.recover;
const stdout = zrx.stdout;
const stderr = zrx.stderr;
const print = zrx.print;

const ParseError = error{ Empty, NotANumber };

fn parse(text: []const u8) ParseError!u32 {
    if (text.len == 0) return error.Empty;
    return std.fmt.parseInt(u32, text, 10) catch error.NotANumber;
}
fn double(value: u32) u32 {
    return value * 2;
}

/// A line that did not parse, and why.
const Rejected = zrx.Failed(ParseError, []const u8);

fn described(rejected: Rejected) struct { []const u8, []const u8 } {
    return .{ rejected.item, @errorName(rejected.err) };
}

/// Where a rejected line goes instead: a pipe like any other.
const rejections = pipe(.{
    map(described),
    print(zrx.Stderr, "rejected \"{s}\": {s}\n"),
});

/// Takes exactly `ParseError`; any other error would still fail the run.
pub const records = pipe(.{
    recover(ParseError, rejections),
    map(parse),
    map(double),
    print(zrx.Stdout, "{d}\n"),
});

pub fn main(init: std.process.Init) !void {
    const input = [_][]const u8{ "21", "", "4", "four" };
    const app = program(fromSlice(&input), records).provide(.{ stdout(256), stderr(256) });
    try app.run(.{init.io});
}
