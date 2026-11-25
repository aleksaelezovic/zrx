//! File I/O: copy the non-empty lines of one file to a new file and report
//! how many were copied. Usage: copy-lines INPUT NEW_OUTPUT
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const filter = zrx.filter;
const fold = zrx.fold;
const branch = zrx.branch;
const rescue = zrx.rescue;
const compose = zrx.compose;
const field = zrx.field;
const ne = zrx.ne;
const print = zrx.print;
const count = zrx.ext.math.count;
const fs = zrx.ext.fs;
const fileLines = fs.fileLines;
const fileWriter = fs.fileWriter;
const process = zrx.ext.process;
const stdout = process.stdout;
const stderr = process.stderr;
const Stdout = process.Stdout;
const Stderr = process.Stderr;

const Copy = struct { writer: *std.Io.Writer };

const isNotEmpty = compose(.{ field(.len), ne(0) });

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    if (args.len != 3) {
        std.debug.print("usage: copy-lines INPUT NEW_OUTPUT\n", .{});
        return 2;
    }
    var exit: process.Exit = .{};
    const input = args[1];
    const output = args[2];

    const write = pipe(.{
        print(Copy, "{f}\n"),
    });
    const report = pipe(.{
        fold(0, count),
        print(Stdout, "copied {d} lines\n"),
    });
    const copy = program(fileLines(input, 4096), pipe(.{
        filter(isNotEmpty),
        branch(.{
            write,
            report,
        }),
    })).provide(.{
        stdout(Stdout, 64),
        // Whatever ends the run, such as an output that already exists: one
        // line on stderr and a status for `main`. The output is closed by then.
        rescue(process.fail(.{})).provide(.{stderr(Stderr, 128)}),
        fileWriter(Copy, output, 4096, .{ .mode = .create_new }),
    });
    copy.run(.{ init.io, &exit });
    return exit.code;
}
