//! Pure command parsing. Argument ownership and effects belong to resources
//! and composition; invalid usage is command data, not an acquisition failure.
const std = @import("std");
const Request = @import("request.zig").Request;
const Fault = @import("fault.zig").Fault;

pub const usage =
    \\Usage: durable-checkout DB KEY CART CENTS [--fault POINT]
    \\       durable-checkout --help
    \\POINT: after-begin | after-insert | after-commit | rollback | output
    \\
;

pub const Checkout = struct {
    path: []const u8,
    request: Request,
    fault: Fault = .none,
};

pub const Command = union(enum) {
    help,
    invalid,
    checkout: Checkout,

    pub fn isHelp(self: Command) bool {
        return self == .help;
    }

    pub fn isInvalid(self: Command) bool {
        return self == .invalid;
    }

    pub fn checkoutRequest(self: Command) Request {
        return self.checkout.request;
    }

    /// Excludes argv[0]. No allocation, I/O, or sentinel requirement.
    pub fn fromArgs(args: []const []const u8) error{InvalidArguments}!Command {
        if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) return .help;
        if (args.len != 4 and args.len != 6) return error.InvalidArguments;
        var fault: Fault = .none;
        if (args.len == 6) {
            if (!std.mem.eql(u8, args[4], "--fault")) return error.InvalidArguments;
            const names = .{ "after-begin", "after-insert", "after-commit", "rollback", "output" };
            const faults = .{ Fault.after_begin, .after_insert, .after_commit, .rollback, .output };
            inline for (names, faults) |name, value| {
                if (std.mem.eql(u8, args[5], name)) fault = value;
            }
            if (fault == .none) return error.InvalidArguments;
        }
        if (args[3].len == 0) return error.InvalidArguments;
        for (args[3]) |byte| {
            if (!std.ascii.isDigit(byte)) return error.InvalidArguments;
        }
        const request = Request{
            .key = args[1],
            .cart = args[2],
            .cents = std.fmt.parseInt(u32, args[3], 10) catch return error.InvalidArguments,
        };
        request.validate() catch return error.InvalidArguments;
        if (args[0].len == 0 or std.mem.eql(u8, args[0], ":memory:") or
            std.mem.indexOfScalar(u8, args[0], 0) != null) return error.InvalidArguments;
        return .{ .checkout = .{ .path = args[0], .fault = fault, .request = request } };
    }
};
