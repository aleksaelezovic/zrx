//! Replays two cold-storage sensor feeds, one program each.
//!
//!     line -> reading -> plausible, or the run fails
//!       |- outside 0 to 8 °C -> labelled alert -> standard output, as seen
//!       '- routine           -> window of 8 readings or 200 ms -> summary -> archive
const std = @import("std");
const Io = std.Io;
const zrx = @import("zrx");
const json = zrx.ext.json;

const pipe = zrx.pipe;
const program = zrx.program;
const system = zrx.system;
const map = zrx.map;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const batchWithin = zrx.batchWithin;
const print = zrx.print;
const write = zrx.write;
const compose = zrx.compose;
const require = zrx.require;
const reduce = zrx.reduce;
const field = zrx.field;
const all = zrx.all;
const any = zrx.any;
const lt = zrx.lt;
const le = zrx.le;
const gt = zrx.gt;
const ge = zrx.ge;
const lines = zrx.lines;
const fileReader = zrx.fileReader;
const fileWriter = zrx.fileWriter;
const stdout = zrx.stdout;

pub const max_line = 64;
pub const window_size = 8;
pub const window_age: Io.Duration = .fromMilliseconds(200);

pub const Line = zrx.Line(max_line);
/// Which sensor a program replays.
pub const Sensor = enum { north, south };
/// Where a feed's readings come from.
pub const Input = struct { reader: *Io.Reader };
/// Where a feed's windows go.
pub const Archive = struct { writer: *Io.Writer };
/// Where a feed's alerts go.
pub const Alerts = zrx.Stdout;

pub const Reading = struct {
    ts_ms: u64,
    temp_mc: i32,
};

pub const Alert = struct {
    sensor: Sensor,
    ts_ms: u64,
    temp_mc: i32,
};

/// The routine readings of one window, in arrival order.
pub const Window = struct {
    first_ts_ms: u64 = 0,
    last_ts_ms: u64 = 0,
    count: u32 = 0,
    min_mc: i32 = std.math.maxInt(i32),
    max_mc: i32 = std.math.minInt(i32),
    sum_mc: i32 = 0,

    pub fn add(window: Window, reading: Reading) Window {
        return .{
            .first_ts_ms = if (window.count == 0) reading.ts_ms else window.first_ts_ms,
            .last_ts_ms = reading.ts_ms,
            .count = window.count + 1,
            .min_mc = @min(window.min_mc, reading.temp_mc),
            .max_mc = @max(window.max_mc, reading.temp_mc),
            .sum_mc = window.sum_mc + reading.temp_mc,
        };
    }
};

fn parse(line: Line) error{InvalidReading}!Reading {
    const text = std.mem.trimEnd(u8, line.text(), "\r");
    const ts_ms, const temp_mc = std.mem.cutScalar(u8, text, ',') orelse return error.InvalidReading;
    return .{
        .ts_ms = std.fmt.parseInt(u64, ts_ms, 10) catch return error.InvalidReading,
        .temp_mc = std.fmt.parseInt(i32, temp_mc, 10) catch return error.InvalidReading,
    };
}

/// -100 to 150 °C is what a sensor can report. It also keeps a window's sum within `i32`.
const isPlausible = compose(.{
    field(.temp_mc),
    all(.{ ge(-100_000), le(150_000) }),
});

/// Outside 0 to 8 °C; both ends are routine.
const needsAlert = compose(.{
    field(.temp_mc),
    any(.{ lt(0), gt(8000) }),
});

fn alert(sensor: Sensor, reading: Reading) Alert {
    return .{ .sensor = sensor, .ts_ms = reading.ts_ms, .temp_mc = reading.temp_mc };
}

const alerts = pipe(.{
    map(alert),
    map(json.encode(.{})),
    print(Alerts, "{f}\n"),
});

const windows = pipe(.{
    batchWithin(window_size, window_age),
    map(reduce(Window{}, Window.add)),
    map(json.encode(.{})),
    write(Archive, "{f}\n"),
});

pub const readings = pipe(.{
    map(parse),
    map(require(isPlausible, error.InvalidReading)),
    route(.{
        when(needsAlert, alerts),
        otherwise(windows),
    }),
});

/// One feed, whatever it reads and wherever it writes.
/// Needs `Sensor`, `Input`, `Archive` and `Alerts`.
pub const feed = program(lines(Input, max_line), readings);

/// Replays `NORTH SOUTH NORTH_OUT SOUTH_OUT` (the arguments without argv[0]).
/// Each feed owns its input, its archive and its writer to standard output.
pub fn execute(io: Io, args: []const []const u8) !void {
    if (args.len != 4) return error.InvalidArguments;
    const north = feed.provide(.{
        Sensor.north,
        fileReader(Input, args[0], max_line + 1),
        fileWriter(Archive, args[2], 4096, .{ .mode = .publish }),
        stdout(256),
    });
    const south = feed.provide(.{
        Sensor.south,
        fileReader(Input, args[1], max_line + 1),
        fileWriter(Archive, args[3], 4096, .{ .mode = .publish }),
        stdout(256),
    });
    try system(.{ north, south }).run(.{io});
}

test "a window keeps the first and last timestamps and the extremes of its readings" {
    const group = [_]Reading{
        .{ .ts_ms = 5, .temp_mc = 4000 },
        .{ .ts_ms = 6, .temp_mc = 0 },
        .{ .ts_ms = 9, .temp_mc = 8000 },
    };
    var window: Window = .{};
    for (group) |reading| window = window.add(reading);
    try std.testing.expectEqual(Window{
        .first_ts_ms = 5,
        .last_ts_ms = 9,
        .count = 3,
        .min_mc = 0,
        .max_mc = 8000,
        .sum_mc = 12000,
    }, window);
}
