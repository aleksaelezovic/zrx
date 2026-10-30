const std = @import("std");
const zrx = @import("zrx");
const stdinLines = zrx.stdinLines;
const fileLines = zrx.fileLines;
const tcpLines = zrx.tcpLines;
const stdoutLines = zrx.stdoutLines;
const stderrLines = zrx.stderrLines;
const writeFileLines = zrx.writeFileLines;
const pipe = zrx.pipe;
const run = zrx.run;

export fn io_file(allocator: *const std.mem.Allocator, io: *const std.Io, input_path: [*]const u8, input_len: usize, output_path: [*]const u8, output_len: usize) bool {
    const source = fileLines(input_path[0..input_len], 128, 2);
    run(allocator.*, io.*, .{
        pipe(&source, .{writeFileLines(output_path[0..output_len], .{ .exclusive = true })}),
    }) catch return false;
    return true;
}

export fn io_stdio(allocator: *const std.mem.Allocator, io: *const std.Io) bool {
    const source = stdinLines(128, 2);
    run(allocator.*, io.*, .{
        pipe(&source, .{stdoutLines()}),
        pipe(&source, .{stderrLines()}),
    }) catch return false;
    return true;
}

export fn io_tcp(allocator: *const std.mem.Allocator, io: *const std.Io, port: u16) bool {
    const source = tcpLines(.{ .ip4 = .loopback(port) }, 128, 2);
    run(allocator.*, io.*, .{pipe(&source, .{stdoutLines()})}) catch return false;
    return true;
}
