//! File I/O: copy the non-empty lines of one file to a new file and report
//! how many were copied. Usage: copy-lines INPUT NEW_OUTPUT
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
const stderr = zrx.stderr;
const rescue = zrx.rescue;
const print = zrx.print;

const Line = zrx.Line(4096);
const Copy = struct { writer: *std.Io.Writer };

fn isNotEmpty(line: Line) bool {
    return line.len != 0;
}
fn count(lines: usize, _: Line) usize {
    return lines + 1;
}

const Exit = struct { code: u8 = 0 };

/// Whatever ends the run, such as an output that already exists: one line
/// on stderr and a status for `main`. The output is closed by then.
fn fatal(err_out: zrx.Stderr, exit: *Exit, err: anyerror) void {
    exit.code = 1;
    err_out.writer.print("error: {s}\n", .{@errorName(err)}) catch return;
    err_out.writer.flush() catch {};
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    if (args.len != 3) {
        std.debug.print("usage: copy-lines INPUT NEW_OUTPUT\n", .{});
        return 2;
    }
    var exit: Exit = .{};
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
    })).provide(.{
        stdout(64),
        stderr(128),
        rescue(fatal),
        fileWriter(Copy, output, 4096, .{ .mode = .create_new }),
    });
    copy.run(.{ init.io, &exit });
    return exit.code;
}
