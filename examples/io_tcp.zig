//! Receive LF-framed `INFO ...` / `WARN ...` events from one TCP peer.
//! Display valid events on stdout; save warnings and invalid events in a new
//! audit file. Usage: io-tcp IP PORT AUDIT_PATH. Peer EOF finishes the program.
const std = @import("std");
const zrx = @import("zrx");
const Line = zrx.Line;
const tcpLines = zrx.tcpLines;
const stdoutLines = zrx.stdoutLines;
const writeFileLines = zrx.writeFileLines;
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const run = zrx.run;
const Text = Line(256);
const Event = struct {
    kind: enum { info, warning, invalid },
    message: Text,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.ExpectedIpPortAndAuditPath;
    const port = try std.fmt.parseInt(u16, args[2], 10);
    const address = try std.Io.net.IpAddress.parse(args[1], port);
    try execute(init.gpa, init.io, address, args[3], stdoutLines());
}

pub fn execute(allocator: std.mem.Allocator, io: std.Io, address: std.Io.net.IpAddress, audit_path: []const u8, display: anytype) !void {
    const input = tcpLines(address, 256, 2);
    const events = pipe(&input, .{each(decodeEvent)});
    const output = pipe(&events, .{ filter(isValid), each(eventLine), display });
    const audit = pipe(&events, .{
        filter(shouldAudit),
        each(eventLine),
        writeFileLines(audit_path, .{ .exclusive = true }),
    });
    try run(allocator, io, .{ output, audit });
}

fn decodeEvent(value: Text) Event {
    const bytes = value.bytes[0..value.len];
    return .{
        .kind = if (std.mem.startsWith(u8, bytes, "INFO ")) .info else if (std.mem.startsWith(u8, bytes, "WARN ")) .warning else .invalid,
        .message = value,
    };
}
fn isValid(value: Event) bool {
    return value.kind != .invalid;
}
fn shouldAudit(value: Event) bool {
    return value.kind != .info;
}
fn eventLine(value: Event) Text {
    return value.message;
}
