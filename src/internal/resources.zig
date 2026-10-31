const std = @import("std");

// Run-private stable resource slots. Allocation/validation precede acquisition;
// acquire must clean up its own partial work, release is non-fallible cleanup.
pub const Claim = union(enum) {
    stdin,
    stdout,
    stderr,
    read_file: []const u8,
    write_file: []const u8,
};

pub const Scope = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        context: *anyopaque,
        claim: ?Claim,
        acquired: bool = false,
        acquire: *const fn (*anyopaque, std.Io) anyerror!void,
        interrupt: ?*const fn (*anyopaque, std.Io) void,
        release: *const fn (*anyopaque, std.Io) void,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn add(self: *@This(), comptime T: type, value: T, claim: ?Claim) !*T {
        if (claim) |requested| for (self.entries.items) |entry| {
            if (entry.claim) |existing| try compatible(existing, requested);
        };
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const slot = try self.allocator.create(T);
        slot.* = value;
        const Calls = struct {
            fn acquire(context: *anyopaque, io: std.Io) !void {
                try cast(context).acquire(io);
            }
            fn release(context: *anyopaque, io: std.Io) void {
                cast(context).release(io);
            }
            fn interrupt(context: *anyopaque, io: std.Io) void {
                cast(context).interrupt(io);
            }
            fn destroy(context: *anyopaque, allocator: std.mem.Allocator) void {
                allocator.destroy(cast(context));
            }
            fn cast(context: *anyopaque) *T {
                return @ptrCast(@alignCast(context));
            }
        };
        self.entries.appendAssumeCapacity(.{
            .context = slot,
            .claim = claim,
            .acquire = Calls.acquire,
            .interrupt = if (@hasDecl(T, "interrupt")) Calls.interrupt else null,
            .release = Calls.release,
            .destroy = Calls.destroy,
        });
        return slot;
    }

    pub fn acquireAll(self: *@This()) !void {
        for (self.entries.items) |*entry| {
            try self.io.checkCancel();
            try entry.acquire(entry.context, self.io);
            entry.acquired = true;
        }
    }

    // Called only after every task which can use a slot has joined.
    pub fn deinit(self: *@This()) void {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            if (entry.acquired) entry.release(entry.context, self.io);
            entry.destroy(entry.context, self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    // Stop blocking resource operations before joining graph producers.
    // This interrupts work without closing/freeing resources still in use.
    pub fn interruptAll(self: *@This()) void {
        for (self.entries.items) |entry| {
            if (entry.acquired) if (entry.interrupt) |interrupt| interrupt(entry.context, self.io);
        }
    }
};

fn compatible(a: Claim, b: Claim) !void {
    switch (a) {
        .stdin, .stdout, .stderr => {
            if (std.meta.activeTag(a) == std.meta.activeTag(b)) return error.DuplicateIoEndpoint;
        },
        .read_file => |path| {
            if (b == .write_file and std.mem.eql(u8, path, b.write_file)) return error.ConflictingIoPaths;
        },
        .write_file => |path| switch (b) {
            .write_file, .read_file => |other| {
                if (std.mem.eql(u8, path, other)) return error.ConflictingIoPaths;
            },
            else => {},
        },
    }
}
