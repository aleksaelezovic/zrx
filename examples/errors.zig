//! A handler error fails the run unless a `recover` upstream handles it.
//! Here good records go to stdout and rejected ones to stderr.
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

/// Handles exactly `ParseError`; any other error would still fail the run.
fn reject(err_out: zrx.Stderr, err: ParseError, text: []const u8) !void {
    try err_out.writer.print("rejected \"{s}\": {s}\n", .{ text, @errorName(err) });
}

pub const records = pipe(.{
    recover(reject),
    map(parse),
    map(double),
    print(zrx.Stdout, "{d}\n"),
});

pub fn main(init: std.process.Init) !void {
    const input = [_][]const u8{ "21", "", "4", "four" };
    const app = program(fromSlice(&input), pipe(.{
        stdout(256),
        stderr(256),
        records,
    }));
    try app.run(.{init.io});
}
