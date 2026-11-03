//! Run-owned invocation and I/O services, not an executor. Each active writer
//! role has one serial writing lane. Release closes owned files without
//! flushing; successful effects explicitly flush and may fail normally.
const std = @import("std");
const zrx = @import("zrx");
const commands = @import("domain/commands.zig");
const resource = zrx.resource;
const deriveResource = zrx.deriveResource;

pub const Input = struct { reader: *zrx.Reader };
pub const AcceptedOutput = struct { writer: ?*zrx.Writer };
pub const DiagnosticOutput = struct { writer: *zrx.Writer };
pub const ConsoleOutput = struct { writer: *zrx.Writer };

fn acquireCommand(args: *zrx.Arguments, _: void) commands.Command {
    const values = args.values;
    return commands.Command.fromArgs(if (values.len == 0) &.{} else values[1..]) catch .invalid;
}

/// Immutable configuration dependency, not a current-record context. A usage
/// mistake is command data; failure to acquire argv remains execution control.
pub fn command() @TypeOf(resource({}, acquireCommand, null)) {
    return resource({}, acquireCommand, null);
}

fn inputConfig(command_value: commands.Command) zrx.Reader.Config {
    const path = if (command_value == .process) command_value.process.input else "-";
    return if (std.mem.eql(u8, path, "-")) .stdin else .{ .file = path };
}

/// Preparing borrowed stdin does not read it. Only process commands open files.
pub fn input() @TypeOf(deriveResource(Input, zrx.reader(inputConfig))) {
    return deriveResource(Input, zrx.reader(inputConfig));
}

fn openAcceptedOutput(allocator: std.mem.Allocator, io: std.Io, config: commands.Command, _: void) !AcceptedOutput {
    if (config != .process) return .{ .writer = null };
    const writer = try allocator.create(zrx.Writer);
    errdefer allocator.destroy(writer);
    writer.* = .{ .output = .{ .file = .{ .path = config.process.output, .options = .{ .exclusive = true } } } };
    try writer.acquire(io);
    return .{ .writer = writer };
}

fn closeAcceptedOutput(allocator: std.mem.Allocator, io: std.Io, output: AcceptedOutput) void {
    if (output.writer) |writer| {
        writer.release(io);
        allocator.destroy(writer);
    }
}

/// Only a processing invocation creates an output file. No dummy file path or
/// unselected-command file effect is needed in the statically declared graph.
pub fn acceptedOutput() @TypeOf(resource({}, openAcceptedOutput, closeAcceptedOutput)) {
    return resource({}, openAcceptedOutput, closeAcceptedOutput);
}

pub fn diagnosticOutput() @TypeOf(deriveResource(DiagnosticOutput, zrx.writer(.stderr))) {
    return deriveResource(DiagnosticOutput, zrx.writer(.stderr));
}

pub fn consoleOutput() @TypeOf(deriveResource(ConsoleOutput, zrx.writer(.stdout))) {
    return deriveResource(ConsoleOutput, zrx.writer(.stdout));
}
