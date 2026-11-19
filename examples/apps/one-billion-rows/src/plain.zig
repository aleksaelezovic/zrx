//! The same aggregate written against `std` alone: what zrx is compared with.
//! A line is borrowed from the read buffer until its station is updated.
const std = @import("std");
const Io = std.Io;
const domain = @import("domain");

const Stations = domain.Stations;

/// The measurements `reader` holds, reported to `writer`.
pub fn aggregate(stations: *Stations, reader: *Io.Reader, writer: *Io.Writer) !void {
    while (try reader.takeDelimiter('\n')) |line| {
        if (line.len > domain.max_line) return error.StreamTooLong;
        const row = try domain.split(line);
        try stations.record(row.station, row.tenths);
    }
    try writer.print("{f}\n", .{stations.report()});
    try writer.flush();
}

/// The measurements in the file at `path`, reported to standard output.
pub fn run(io: Io, stations: *Stations, path: []const u8) !void {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var input_buffer: [domain.read_bytes]u8 = undefined;
    var input = file.reader(io, &input_buffer);
    var output_buffer: [domain.write_bytes]u8 = undefined;
    var output = Io.File.stdout().writerStreaming(io, &output_buffer);
    try aggregate(stations, &input.interface, &output.interface);
}
