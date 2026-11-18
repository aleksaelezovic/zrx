const std = @import("std");
const zrx = @import("zrx");
const domain = @import("domain");
const forEach = zrx.forEach;

const Input = struct { reader: *std.Io.Reader };
const Line = zrx.Line(domain.max_line);

fn add(stations: *domain.Stations, line: Line) !void {
    try stations.add(line.text());
}

pub fn read(stations: *domain.Stations, input: *std.Io.Reader) !void {
    const program = zrx.program(zrx.lines(Input, domain.max_line), .{
        forEach(add),
    });
    try program.run(.{ stations, Input{ .reader = input } });
}
