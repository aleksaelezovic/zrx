//! Compile-only fixture for the cross-target catalog: everything that needs an
//! operating system (tasks, queues, files, standard streams).
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;

const Copy = struct { writer: *std.Io.Writer };

fn double(value: u32) u32 {
    return value *% 2;
}
fn add(sum: u64, value: u32) u64 {
    return sum +% value;
}
fn length(line: []const u8) u32 {
    return @intCast(line.len);
}

export fn zrx_cross_tasks(io: *const std.Io, first: u32, end: u32) bool {
    const totals = program(zrx.merge(.{ zrx.range(u32, first, end), zrx.range(u32, first, end) }), pipe(.{
        zrx.queue(8),
        zrx.map(double),
        zrx.branch(.{
            pipe(.{ zrx.queue(2), zrx.fold(0, add), zrx.stdout(64), zrx.print(zrx.Stdout, "{d}\n") }),
            pipe(.{ zrx.take(1), zrx.stderr(64), zrx.print(zrx.Stderr, "{d}\n") }),
        }),
    }));
    zrx.system(.{ totals, totals }).run(.{io.*}) catch return false;
    return true;
}

export fn zrx_cross_files(io: *const std.Io, from: [*:0]const u8, to: [*:0]const u8) bool {
    const copy = program(zrx.fileLines(std.mem.span(from), 256), pipe(.{
        zrx.createFile(Copy, std.mem.span(to), 256, .{}),
        zrx.print(Copy, "{s}\n"),
    }));
    const measure = program(zrx.stdinLines(256), pipe(.{ zrx.map(length), zrx.drain() }));
    copy.run(.{io.*}) catch return false;
    measure.run(.{io.*}) catch return false;
    return true;
}
