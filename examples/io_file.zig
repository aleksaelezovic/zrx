//! Copy bounded LF-framed records to a new file. Usage: copy-lines INPUT OUTPUT.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const fileLines = zrx.fileLines;
const writeFileLines = zrx.writeFileLines;
const run = zrx.run;

pub fn program(input: []const u8, output: []const u8) @TypeOf(pipe(fileLines(input, 256, 1), .{writeFileLines(output, .{ .exclusive = true })})) {
    return pipe(fileLines(input, 256, 1), .{writeFileLines(output, .{ .exclusive = true })});
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedInputAndOutputPaths;
    try run(.{ init.gpa, init.io }, .{program(args[1], args[2])});
}
