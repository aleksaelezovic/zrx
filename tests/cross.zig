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
fn length(line: zrx.Line(256)) u32 {
    return @intCast(line.len);
}

export fn zrx_cross_tasks(io: *const std.Io, first: u32, end: u32) bool {
    const totals = program(zrx.merge(.{ zrx.range(u32, first, end), zrx.range(u32, first, end) }), pipe(.{
        zrx.queue(8),
        zrx.map(double),
        zrx.branch(.{
            pipe(.{ zrx.queue(2), zrx.fold(0, add), zrx.print(zrx.Stdout, "{d}\n") }),
            pipe(.{ zrx.take(1), zrx.print(zrx.Stderr, "{d}\n") }),
        }),
    })).provide(.{ zrx.stdout(64), zrx.stderr(64) });
    zrx.system(.{ totals, totals }).run(.{io.*}) catch return false;
    return true;
}

export fn zrx_cross_files(io: *const std.Io, from: [*:0]const u8, to: [*:0]const u8) bool {
    const copy = program(zrx.fileLines(std.mem.span(from), 256), pipe(.{
        zrx.print(Copy, "{f}\n"),
    })).provide(.{zrx.fileWriter(Copy, std.mem.span(to), 256, .{})});
    const measure = program(zrx.stdinLines(256), pipe(.{ zrx.map(length), zrx.drain() }));
    copy.run(.{io.*}) catch return false;
    measure.run(.{io.*}) catch return false;
    return true;
}

export fn zrx_cross_json(writer: *std.Io.Writer, first: u32, end: u32) bool {
    const numbers = program(zrx.range(u32, first, end), .{
        zrx.map(zrx.ext.json.encode(.{})),
        zrx.write(*std.Io.Writer, "{f}\n"),
    });
    numbers.run(.{writer}) catch return false;
    return true;
}

export fn zrx_cross_timing(io: *const std.Io, first: u32, end: u32) bool {
    const batches = program(zrx.range(u32, first, end), pipe(.{
        zrx.batchWithin(1000, .fromSeconds(60)),
        zrx.flatten(),
        zrx.drain(),
    }));
    const latest = program(zrx.range(u32, first, end), pipe(.{
        zrx.debounce(.fromMilliseconds(250)),
        zrx.drain(),
    }));
    zrx.system(.{ batches, latest }).run(.{io.*}) catch return false;
    return true;
}

export fn zrx_cross_concurrent(io: *const std.Io, first: u32, end: u32) bool {
    const app = program(zrx.range(u32, first, end), .{
        zrx.concurrent(4, .{ zrx.map(double), zrx.fold(@as(u64, 0), add) }),
        zrx.drain(),
    });
    app.run(.{io.*}) catch return false;
    return true;
}

fn stopAware(stop: zrx.Stop, io: std.Io, out: anytype) !void {
    if (try out.push(1) == .more) try stop.wait(io);
}

export fn zrx_cross_completion(io: *const std.Io) bool {
    const left = pipe(.{ zrx.queue(1), zrx.take(1), zrx.drain() });
    const right = pipe(.{ zrx.take(1), zrx.drain() });
    const work = program(zrx.fromProducer(u32, stopAware), pipe(.{zrx.branch(.{ left, right })}));
    work.run(.{io.*}) catch return false;
    return true;
}
