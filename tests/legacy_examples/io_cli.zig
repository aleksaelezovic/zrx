//! A line command interpreter. `ping` replies `pong`; `upper TEXT` replies in
//! ASCII uppercase. Invalid commands go to stderr; blank input is ignored.
//! EOF finishes both pipes. There is deliberately no implicit quit/cancel rule.
//! Archived I/O regression, not a public API example.
const std = @import("std");
const zrx = @import("zrx");
const Line = zrx.Line;
const line = zrx.line;
const stdinLines = zrx.stdinLines;
const stdoutLines = zrx.stdoutLines;
const stderrLines = zrx.stderrLines;
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const run = zrx.run;
const Text = Line(256);
const Command = union(enum) { ping, upper: Text, invalid };
const Decision = union(enum) { reply: Text, diagnostic: Text };

pub fn main(init: std.process.Init) !void {
    const input = stdinLines(256, 2);
    try execute(init.gpa, init.io, &input, stdoutLines(), stderrLines());
}

// Tests select finite input/file endpoints, exercising this exact same graph.
pub fn execute(allocator: std.mem.Allocator, io: std.Io, input: anytype, output: anytype, diagnostics: anytype) !void {
    const decisions = pipe(input, .{ filter(isNonempty), each(.{ parseCommand, decide }) });
    const replies = pipe(&decisions, .{ filter(isReply), each(reply), output });
    const errors = pipe(&decisions, .{ filter(isDiagnostic), each(diagnostic), diagnostics });
    try run(allocator, io, .{ replies, errors });
}

fn isNonempty(value: Text) bool {
    return value.len != 0;
}
fn parseCommand(value: Text) Command {
    const bytes = value.bytes[0..value.len];
    if (std.mem.eql(u8, bytes, "ping")) return .ping;
    if (std.mem.startsWith(u8, bytes, "upper "))
        return .{ .upper = line(256, bytes["upper ".len..]) catch unreachable };
    return .invalid;
}
fn decide(command: Command) Decision {
    return switch (command) {
        .ping => .{ .reply = line(256, "pong") catch unreachable },
        .upper => |text| block: {
            var result = text;
            for (result.bytes[0..result.len]) |*byte| byte.* = std.ascii.toUpper(byte.*);
            break :block .{ .reply = result };
        },
        .invalid => .{ .diagnostic = line(256, "error: expected ping or upper TEXT") catch unreachable },
    };
}
fn isReply(value: Decision) bool {
    return value == .reply;
}
fn isDiagnostic(value: Decision) bool {
    return value == .diagnostic;
}
fn reply(value: Decision) Text {
    return value.reply;
}
fn diagnostic(value: Decision) Text {
    return value.diagnostic;
}
