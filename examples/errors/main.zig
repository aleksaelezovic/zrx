//! A handler error fails the run unless a `recover` before it takes it. Here
//! good records go to stdout and rejected ones down a path of their own.
//! Whatever still fails the run goes to a `rescue`.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const recover = zrx.recover;
const rescue = zrx.rescue;
const print = zrx.print;
const mul = zrx.ext.math.mul;
const process = zrx.ext.process;
const stdout = process.stdout;
const stderr = process.stderr;
const Stdout = process.Stdout;
const Stderr = process.Stderr;

const ParseError = error{ Empty, NotANumber };

fn parse(text: []const u8) ParseError!u32 {
    if (text.len == 0) return error.Empty;
    return std.fmt.parseInt(u32, text, 10) catch error.NotANumber;
}

/// A line that did not parse, and why.
const Rejected = zrx.Failed(ParseError, []const u8);

fn described(rejected: Rejected) struct { []const u8, []const u8 } {
    return .{ rejected.item, @errorName(rejected.err) };
}

/// Where a rejected line goes instead: a pipe like any other.
const rejections = pipe(.{
    map(described),
    print(Stderr, "rejected \"{s}\": {s}\n"),
});

/// Takes exactly `ParseError`; any other error would still fail the run.
pub const records = pipe(.{
    recover(ParseError, rejections),
    map(parse),
    map(mul(2)),
    print(Stdout, "{d}\n"),
});

/// What belongs to no line, such as a write that fails, ends the run. A run
/// returns nothing: the failure goes to a rescue, which reports it and
/// leaves a status for `main`. It is called when the run is over, with a
/// stderr of its own: the run's has been released by then.
const fatal = rescue(process.fail(.{ .prefix = "fatal" })).provide(.{stderr(Stderr, 64)});

pub fn main(init: std.process.Init) u8 {
    var exit: process.Exit = .{};
    const input = [_][]const u8{ "21", "", "4", "four" };
    const app = program(fromSlice(&input), records).provide(.{
        stdout(Stdout, 256),
        stderr(Stderr, 256),
        fatal,
    });
    app.run(.{ init.io, &exit });
    return exit.code;
}
