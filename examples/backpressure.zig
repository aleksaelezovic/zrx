//! `queue` is the concurrency boundary. A branch that starts with a queue runs
//! on its own task; when its buffer is full the producer waits, so a slow
//! consumer slows the source down instead of losing items or growing memory.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const rescue = zrx.rescue;
const range = zrx.range;
const map = zrx.map;
const tap = zrx.tap;
const fold = zrx.fold;
const reduce = zrx.reduce;
const batch = zrx.batch;
const queue = zrx.queue;
const branch = zrx.branch;
const print = zrx.print;
const sum = zrx.ext.math.sum;
const process = zrx.ext.process;
const stdout = process.stdout;
const stderr = process.stderr;
const Stdout = process.Stdout;
const Stderr = process.Stderr;

fn slowWrite(io: std.Io, _: u32) !void {
    try io.sleep(.fromMilliseconds(1), .awake);
}

/// A slow sink behind a small buffer.
const archive = pipe(.{
    queue(4),
    tap(slowWrite),
    fold(@as(u64, 0), sum),
    print(Stdout, "archived sum: {d}\n"),
});

/// A fast aggregation that keeps running while the archive catches up.
const report = pipe(.{
    queue(16),
    batch(10),
    map(reduce(@as(u64, 0), sum)),
    print(Stderr, "batch sum: {d}\n"),
});

pub fn main(init: std.process.Init) u8 {
    var exit: process.Exit = .{};
    const app = program(range(u32, 1, 31), pipe(.{
        branch(.{
            archive,
            report,
        }),
    })).provide(.{
        stdout(Stdout, 64),
        stderr(Stderr, 128),
    });
    // A run returns nothing: what ends it goes to a rescue, and here becomes
    // the exit status.
    app.run(.{ init.io, &exit, rescue(process.fail(.{ .prefix = null })) });
    return exit.code;
}
