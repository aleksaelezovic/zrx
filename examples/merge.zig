//! Convert distinct inputs into an explicit event union, then apply named
//! decisions and service effects. Each input stays ordered; their interleaving
//! is deliberately unspecified. No implicit source tagging or deduplication.
const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const each = zrx.each;
const merge = zrx.merge;
const forEachWith = zrx.forEachWith;
const run = zrx.run;

const Command = enum { enable, disable };
const Event = union(enum) { command: Command, reading: u16 };
const Action = union(enum) { enabled: bool, display: u16 };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var screen: Screen = .{ .writer = &writer };

    const commands: Stream(Command) = .fromProducer(1, receiveCommands);
    const readings: Stream(u16) = .fromProducer(1, receiveReadings);
    const events = merge(.{
        pipe(&commands, .{each(asCommandEvent)}),
        pipe(&readings, .{each(asReadingEvent)}),
    });
    const displayFlow = pipe(&events, .{
        each(decide),
        forEachWith(&screen, Screen.render),
    });
    try run(allocator, io, .{displayFlow});
    if (screen.actions != 5) return error.UnexpectedResult;
    std.debug.print("Merged actions (cross-source order may vary):\n{s}", .{writer.buffered()});
}

fn receiveCommands(output: *Emitter(Command)) !void {
    try output.push(.enable);
    try output.push(.disable);
}

fn receiveReadings(output: *Emitter(u16)) !void {
    for ([_]u16{ 10, 20, 30 }) |value| try output.push(value);
}

fn asCommandEvent(command: Command) Event {
    return .{ .command = command };
}

fn asReadingEvent(reading: u16) Event {
    return .{ .reading = reading };
}

fn decide(event: Event) Action {
    return switch (event) {
        .command => |command| .{ .enabled = command == .enable },
        .reading => |reading| .{ .display = reading },
    };
}

const Screen = struct {
    writer: *std.Io.Writer,
    actions: usize = 0,
    fn render(self: *@This(), action: Action) !void {
        switch (action) {
            .enabled => |enabled| try self.writer.print("Enabled: {}\n", .{enabled}),
            .display => |reading| try self.writer.print("Reading: {d}\n", .{reading}),
        }
        self.actions += 1;
    }
};
