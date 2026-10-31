//! Extract lines prefixed `keep ` into a new file; other lines go to stderr.
//! Usage: io-file INPUT OUTPUT. OUTPUT must not exist. Partial output is not
//! rolled back on failure. No files are opened in declaration/setup code.
//! Archived I/O regression, not a public API example.
const std = @import("std");
const zrx = @import("zrx");
const Line = zrx.Line;
const line = zrx.line;
const fileLines = zrx.fileLines;
const writeFileLines = zrx.writeFileLines;
const stderrLines = zrx.stderrLines;
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const run = zrx.run;
const Text = Line(256);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedInputAndOutputPaths;
    try execute(init.gpa, init.io, args[1], args[2], stderrLines());
}

pub fn execute(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8, output_path: []const u8, rejected_output: anytype) !void {
    const input = fileLines(input_path, 256, 2);
    const selected = pipe(&input, .{
        filter(isSelected),
        each(removePrefix),
        writeFileLines(output_path, .{ .exclusive = true }),
    });
    const rejected = pipe(&input, .{ filter(isRejected), rejected_output });
    try run(allocator, io, .{ selected, rejected });
}

fn isSelected(value: Text) bool {
    return std.mem.startsWith(u8, value.bytes[0..value.len], "keep ");
}
fn isRejected(value: Text) bool {
    return !isSelected(value);
}
fn removePrefix(value: Text) Text {
    return line(256, value.bytes["keep ".len..value.len]) catch unreachable;
}
