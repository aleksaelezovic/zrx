//! The command line both servers share.
const std = @import("std");
const Io = std.Io;

pub const Command = union(enum) {
    help,
    serve: u16,

    pub fn parse(args: []const []const u8) !Command {
        if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) return .help;
        if (args.len != 2 or !std.mem.eql(u8, args[0], "serve")) return error.InvalidArguments;
        return .{ .serve = std.fmt.parseInt(u16, args[1], 10) catch return error.InvalidPort };
    }
};

/// Does what the arguments ask, with `serve(io, port)` as the server.
/// Anything that fails is one line on stderr, the usage, and exit status 2.
pub fn main(init: std.process.Init, comptime name: []const u8, comptime serve: anytype) void {
    const usage = "usage: " ++ name ++ " serve PORT\n";
    run(init, usage, serve) catch |err| {
        var buffer: [256]u8 = undefined;
        var writer = Io.File.stderr().writerStreaming(init.io, &buffer);
        writer.interface.print("fatal: {s}\n{s}", .{ @errorName(err), usage }) catch {};
        writer.interface.flush() catch {};
        std.process.exit(2);
    };
}

fn run(init: std.process.Init, comptime usage: []const u8, comptime serve: anytype) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    switch (try Command.parse(args[1..])) {
        .help => try Io.File.stdout().writeStreamingAll(init.io, usage),
        .serve => |port| try serve(init.io, port),
    }
}

test "the command line is a port to serve on, or a request for help" {
    try std.testing.expectEqual(Command{ .serve = 8080 }, try Command.parse(&.{ "serve", "8080" }));
    try std.testing.expectEqual(Command.help, try Command.parse(&.{"--help"}));
    try std.testing.expectError(error.InvalidPort, Command.parse(&.{ "serve", "http" }));
    try std.testing.expectError(error.InvalidArguments, Command.parse(&.{}));
    try std.testing.expectError(error.InvalidArguments, Command.parse(&.{ "serve", "8080", "16" }));
}
