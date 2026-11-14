//! `queue` is the concurrency boundary. A branch that starts with a queue runs
//! on its own task; when its buffer is full the producer waits, so a slow
//! consumer slows the source down instead of losing items or growing memory.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const tap = zrx.tap;
const scan = zrx.scan;
const fold = zrx.fold;
const batch = zrx.batch;
const queue = zrx.queue;
const branch = zrx.branch;
const stdout = zrx.stdout;
const stderr = zrx.stderr;
const print = zrx.print;

fn slowWrite(io: std.Io, _: u32) !void {
    try io.sleep(.fromMilliseconds(1), .awake);
}
fn add(sum: u64, value: u32) u64 {
    return sum + value;
}
fn sumOf(values: zrx.Batch(u32, 10)) u64 {
    var total: u64 = 0;
    for (values.slice()) |value| total += value;
    return total;
}

/// A slow sink behind a small buffer.
const archive = pipe(.{
    queue(4),
    tap(slowWrite),
    fold(0, add),
    print(zrx.Stdout, "archived sum: {d}\n"),
});

/// A fast aggregation that keeps running while the archive catches up.
const report = pipe(.{
    queue(16),
    batch(10),
    map(sumOf),
    print(zrx.Stderr, "batch sum: {d}\n"),
});

pub fn main(init: std.process.Init) !void {
    const app = program(range(u32, 1, 31), pipe(.{
        branch(.{
            archive,
            report,
        }),
    })).provide(.{ stdout(64), stderr(128) });
    try app.run(.{init.io});
}
