//! A system is several programs run together with the same dependencies.
//! Here one program parses readings and posts alerts to a mailbox; another
//! drains the mailbox and reports. The mailbox is an ordinary dependency.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const system = zrx.system;
const fromSlice = zrx.fromSlice;
const fromProducer = zrx.fromProducer;
const map = zrx.map;
const filter = zrx.filter;
const resource = zrx.resource;
const subscribe = zrx.subscribe;
const compose = zrx.compose;
const field = zrx.field;
const gt = zrx.gt;
const stdout = zrx.stdout;
const print = zrx.print;

const Reading = struct { sensor: u8, celsius: i32 };
const Alert = struct { sensor: u8, celsius: i32 };

/// A bounded channel between programs.
const Mailbox = struct {
    io: std.Io,
    queue: std.Io.Queue(Alert),
};

/// Held by the sending program for as long as it runs; hanging up tells the
/// receiver that no more alerts will come.
const Line = struct { mailbox: *Mailbox };

fn dial(mailbox: *Mailbox) Line {
    return .{ .mailbox = mailbox };
}
fn hangUp(line: Line) void {
    line.mailbox.queue.close(line.mailbox.io);
}

fn toAlert(reading: Reading) Alert {
    return .{ .sensor = reading.sensor, .celsius = reading.celsius };
}
fn post(line: Line, alert: Alert) !void {
    try line.mailbox.queue.putOne(line.mailbox.io, alert);
}
fn receive(mailbox: *Mailbox, out: anytype) !void {
    while (true) {
        const alert = mailbox.queue.getOne(mailbox.io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        if (try out.push(alert) == .done) return;
    }
}
fn describe(alert: Alert) struct { u8, i32 } {
    return .{ alert.sensor, alert.celsius };
}

const isHot = compose(.{ field(.celsius), gt(80) });

pub fn main(init: std.process.Init) !void {
    const readings = [_]Reading{
        .{ .sensor = 1, .celsius = 40 },
        .{ .sensor = 2, .celsius = 95 },
        .{ .sensor = 1, .celsius = 81 },
        .{ .sensor = 3, .celsius = 20 },
    };
    var slots: [8]Alert = undefined;
    var mailbox: Mailbox = .{ .io = init.io, .queue = .init(&slots) };

    const monitor = program(fromSlice(&readings), pipe(.{
        filter(isHot),
        map(toAlert),
        subscribe(post),
    })).provide(.{resource(dial, hangUp)});
    const notifier = program(fromProducer(Alert, receive), pipe(.{
        map(describe),
        print(zrx.Stdout, "sensor {d} is at {d} C\n"),
    })).provide(.{stdout(128)});
    try system(.{ monitor, notifier }).run(.{ init.io, &mailbox });
}
