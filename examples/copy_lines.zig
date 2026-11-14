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
const fileWriter = zrx.fileWriter;
const stdout = zrx.stdout;
const print = zrx.print;

const Line = zrx.Line(4096);
const Copy = struct { writer: *std.Io.Writer };

fn isNotEmpty(line: Line) bool {
    return line.len != 0;
}
fn count(lines: usize, _: Line) usize {
    return lines + 1;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: copy-lines INPUT OUTPUT\n", .{});
        std.process.exit(2);
    }
    const input = args[1];
    const output = args[2];

    const write = pipe(.{
        print(Copy, "{f}\n"),
    });
    const report = pipe(.{
        fold(0, count),
        print(zrx.Stdout, "copied {d} lines\n"),
    });
    const copy = program(fileLines(input, 4096), pipe(.{
        filter(isNotEmpty),
        branch(.{
            write,
            report,
        }),
    })).provide(.{ fileWriter(Copy, output, 4096, .{}), stdout(64) });
    try copy.run(.{init.io});
}
