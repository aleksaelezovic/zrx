//! The One Billion Row Challenge with zrx: two programs, run one after the other.
//!
//!     line -> station and temperature -> that station's statistics
//!     the statistics, in order        -> the report
const std = @import("std");
const Io = std.Io;
const zrx = @import("zrx");
const domain = @import("domain");

const program = zrx.program;
const map = zrx.map;
const forEach = zrx.forEach;
const print = zrx.print;
const lines = zrx.lines;
const fromProducer = zrx.fromProducer;
const fileReader = zrx.fileReader;
const stdout = zrx.stdout;

const Stations = domain.Stations;
const Line = zrx.Line(domain.max_line);
const Name = zrx.Line(domain.max_name);

/// Where the measurements come from.
pub const Input = struct { reader: *Io.Reader };
/// Where the report goes.
pub const Output = zrx.Stdout;

/// What one line says. The name is a copy: an item does not point into
/// the line it was read from.
const Measurement = struct { station: Name, tenths: i16 };

fn parse(line: Line) !Measurement {
    const row = try domain.split(line.text());
    return .{ .station = try .from(row.station), .tenths = row.tenths };
}

fn record(stations: *Stations, measurement: Measurement) !void {
    try stations.record(measurement.station.text(), measurement.tenths);
}

fn inOrder(stations: *Stations, out: anytype) !void {
    _ = try out.push(stations.report());
}

/// Needs `Input` and the `*Stations` the statistics are kept in.
pub const measuring = program(lines(Input, domain.max_line), .{
    map(parse),
    forEach(record),
});

/// Needs the `*Stations` and `Output`.
pub const reporting = program(fromProducer(domain.Report, inOrder), .{print(Output, "{f}\n")});

/// The measurements `reader` holds, reported to `writer`.
pub fn aggregate(stations: *Stations, reader: *Io.Reader, writer: *Io.Writer) !void {
    try measuring.run(.{ stations, Input{ .reader = reader } });
    try reporting.run(.{ stations, Output{ .writer = writer } });
}

/// The measurements in the file at `path`, reported to standard output.
pub fn run(io: Io, stations: *Stations, path: []const u8) !void {
    try measuring.run(.{ io, stations, fileReader(Input, path, domain.read_bytes) });
    try reporting.run(.{ io, stations, stdout(domain.write_bytes) });
}
