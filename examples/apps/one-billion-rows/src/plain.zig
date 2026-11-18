const std = @import("std");
const domain = @import("domain");

pub fn read(stations: *domain.Stations, input: *std.Io.Reader) !void {
    while (try input.takeDelimiter('\n')) |line| {
        if (line.len > domain.max_line) return error.StreamTooLong;
        try stations.add(line);
    }
}
