//! Capture at most COUNT TCP line records without waiting for peer EOF.
//! One shared prefix feeds stdout and a new output file. Usage:
//! io-tcp-take IP PORT COUNT OUTPUT_PATH. COUNT=0 still acquires selected resources.
const std = @import("std");
const zrx = @import("zrx");
const tcpLines = zrx.tcpLines;
const stdoutLines = zrx.stdoutLines;
const writeFileLines = zrx.writeFileLines;
const pipe = zrx.pipe;
const take = zrx.take;
const run = zrx.run;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.ExpectedIpPortCountAndOutputPath;
    const port = try std.fmt.parseInt(u16, args[2], 10);
    const address = try std.Io.net.IpAddress.parse(args[1], port);
    const count = try std.fmt.parseInt(usize, args[3], 10);
    try execute(init.gpa, init.io, address, count, args[4], stdoutLines());
}

pub fn execute(allocator: std.mem.Allocator, io: std.Io, address: std.Io.net.IpAddress, count: usize, output_path: []const u8, display: anytype) !void {
    const input = tcpLines(address, 256, 2);
    const prefix = pipe(&input, .{take(count)});
    const output = pipe(&prefix, .{display});
    const capture = pipe(&prefix, .{writeFileLines(output_path, .{ .exclusive = true })});
    try run(allocator, io, .{ output, capture });
}
