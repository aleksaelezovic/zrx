const std = @import("std");
const jobs = @import("jobs.zig");

pub const Config = struct {
    port: u16 = 0,
    connections: ?usize = 0,
    max_jobs: usize = 64,
    body_bytes: usize = 1024,
    max_values: usize = jobs.max_values,

    pub fn validate(self: Config) !void {
        if (self.max_jobs == 0 or self.max_jobs > 1024 or
            self.body_bytes == 0 or self.body_bytes > 4096 or
            self.max_values == 0 or self.max_values > jobs.max_values)
            return error.InvalidLimits;
    }

    /// Pure option parsing; argv[0] is not part of this slice.
    /// No default live listener: finite serving requires a connection count.
    pub fn fromArgs(args: []const []const u8) !Config {
        if (args.len < 2) return error.ExpectedServePortCountOrLivePort;
        const live = std.mem.eql(u8, args[0], "live");
        if (!live and !std.mem.eql(u8, args[0], "serve")) return error.ExpectedServeOrLive;
        const required: usize = if (live) 2 else 3;
        if (args.len < required or args.len > required + 3) return error.InvalidArgumentCount;
        var result: Config = .{
            .port = try std.fmt.parseInt(u16, args[1], 10),
            .connections = if (live) null else try std.fmt.parseInt(usize, args[2], 10),
        };
        if (args.len > required) result.max_jobs = try std.fmt.parseInt(usize, args[required], 10);
        if (args.len > required + 1) result.body_bytes = try std.fmt.parseInt(usize, args[required + 1], 10);
        if (args.len > required + 2) result.max_values = try std.fmt.parseInt(usize, args[required + 2], 10);
        try result.validate();
        return result;
    }
};
