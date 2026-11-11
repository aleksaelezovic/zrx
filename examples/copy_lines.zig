//! File I/O: copy the non-empty lines of one file to another and report how
//! many were copied. Usage: copy-lines INPUT OUTPUT
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const fileLines = zrx.fileLines;
const filter = zrx.filter;
const fold = zrx.fold;
const branch = zrx.branch;
const createFile = zrx.createFile;
const stdout = zrx.stdout;
const print = zrx.print;

const Copy = struct { writer: *std.Io.Writer };

fn isNotEmpty(line: []const u8) bool {
    return line.len != 0;
}
fn count(lines: usize, _: []const u8) usize {
    return lines + 1;
}

pub fn copy(input: []const u8, output: []const u8) @TypeOf(program(fileLines(input, 4096), pipe(.{
    filter(isNotEmpty),
    branch(.{
        pipe(.{ createFile(Copy, output, 4096), print(Copy, "{s}\n") }),
        pipe(.{ fold(0, count), stdout(64), print(zrx.Stdout, "copied {d} lines\n") }),
    }),
}))) {
    return program(fileLines(input, 4096), pipe(.{
        filter(isNotEmpty),
        branch(.{
            pipe(.{ createFile(Copy, output, 4096), print(Copy, "{s}\n") }),
            pipe(.{ fold(0, count), stdout(64), print(zrx.Stdout, "copied {d} lines\n") }),
        }),
    }));
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: copy-lines INPUT OUTPUT\n", .{});
        std.process.exit(2);
    }
    try copy(args[1], args[2]).run(.{init.io});
}
