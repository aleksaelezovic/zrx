const std = @import("std");
const streams = @import("streams.zig");
const sequences = @import("../../data/sequences.zig");

// Cache synchronization belongs to one execution, not to declarations.

pub const Reporter = struct {
    context: *anyopaque,
    fail: *const fn (*anyopaque, anyerror) void,
};

pub const Entry = struct {
    context: *anyopaque,
    parent: ?*Entry = null,
    compute: *const fn (*Entry) void,
    commit: *const fn (*Entry) void,
    publish: *const fn (*Entry) anyerror!void,
    close: *const fn (*Entry, ?anyerror) void,
    destroy: *const fn (*Entry, std.mem.Allocator) void,
};

// A single-parent derivation tree shares one serial update loop and commit lock.
// User transforms run outside the lock; only copying candidates occurs inside.
pub const Family = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayList(*Entry) = .empty,
    context: *anyopaque,
    drive: *const fn (*Family) anyerror!void,
    task: ?std.Io.Future(void) = null,
    first_error: ?anyerror = null,

    pub fn start(self: *@This(), armed: *std.Io.Event, reporter: Reporter) !void {
        self.task = try self.io.concurrent(work, .{ self, armed, reporter });
    }

    fn work(self: *@This(), armed: *std.Io.Event, reporter: Reporter) void {
        self.gated(armed) catch |err| {
            self.mutex.lockUncancelable(self.io);
            if (self.first_error == null) self.first_error = err;
            const failure = self.first_error.?;
            self.mutex.unlock(self.io);
            for (self.entries.items) |entry| entry.close(entry, failure);
            reporter.fail(reporter.context, failure);
            return;
        };
        for (self.entries.items) |entry| entry.close(entry, null);
    }

    fn gated(self: *@This(), armed: *std.Io.Event) !void {
        try armed.wait(self.io);
        try self.drive(self);
    }

    pub fn initialize(self: *@This()) !void {
        try self.evaluateAndPublish();
    }

    pub fn evaluateAndPublish(self: *@This()) !void {
        for (self.entries.items) |entry| {
            try self.io.checkCancel();
            entry.compute(entry);
        }
        try self.mutex.lock(self.io);
        for (self.entries.items) |entry| entry.commit(entry);
        self.mutex.unlock(self.io);
        // Publication may block. Neither queues nor effects hold the cache lock.
        for (self.entries.items) |entry| {
            try self.io.checkCancel();
            try entry.publish(entry);
        }
    }

    pub fn stop(self: *@This()) void {
        if (self.task) |*task| task.cancel(self.io);
    }

    pub fn destroy(self: *@This(), allocator: std.mem.Allocator) void {
        // All samplers/stream workers must also have joined before cache disposal.
        for (self.entries.items) |entry| entry.destroy(entry, allocator);
        self.entries.deinit(allocator);
        allocator.destroy(self);
    }
};

pub fn Cell(comptime T: type) type {
    return struct {
        const Self = @This();
        entry: Entry,
        family: *Family,
        current: T = undefined,
        candidate: T = undefined,
        updates: ?*streams.Stream(T).Reader = null,
        observation: ?*streams.Stream(T) = null,
        observation_node: ?*anyopaque = null,
        binding: ?*anyopaque = null,

        pub fn create(allocator: std.mem.Allocator, family: *Family) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .entry = .{
                    .context = self,
                    .compute = unchanged,
                    .commit = commit,
                    .publish = publish,
                    .close = close,
                    .destroy = destroy,
                },
                .family = family,
            };
            return self;
        }

        pub fn cast(entry: *Entry) *Self {
            return @ptrCast(@alignCast(entry.context));
        }

        fn unchanged(_: *Entry) void {}
        fn commit(entry: *Entry) void {
            const self = cast(entry);
            self.current = self.candidate;
        }
        fn publish(entry: *Entry) !void {
            const self = cast(entry);
            if (self.observation) |output| output.push(self.candidate) catch |err| switch (err) {
                // An observation prefix can finish while this family remains
                // sampleable by other flows. Closed delivery is not state failure.
                error.Closed => {},
                else => return err,
            };
        }
        fn close(entry: *Entry, err: ?anyerror) void {
            if (cast(entry).observation) |output| {
                if (err) |failure| output.fail(failure) else output.close();
            }
        }
        fn destroy(entry: *Entry, allocator: std.mem.Allocator) void {
            allocator.destroy(cast(entry));
        }

        pub fn driveRoot(family: *Family) !void {
            const self: *Self = @ptrCast(@alignCast(family.context));
            var input = self.updates.?.iterator();
            while (true) {
                try family.io.checkCancel();
                const value = (try input.next()) orelse return;
                self.candidate = value;
                try family.evaluateAndPublish();
            }
        }

        // A wrapper keeps bare error-set T legal as data inside an error result.
        pub fn snapshot(self: *Self) anyerror!struct { value: T } {
            try self.family.mutex.lock(self.family.io);
            defer self.family.mutex.unlock(self.family.io);
            if (self.family.first_error) |err| return err;
            return .{ .value = self.current };
        }
    };
}

pub fn sample(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: anytype,
    comptime T: type,
    cell: *Cell(T),
) !streams.Stream(@Tuple(&.{ sequences.Item(@TypeOf(input)), T })) {
    const Input = @TypeOf(input);
    const Pair = @Tuple(&.{ sequences.Item(Input), T });
    const Context = struct { input: Input, cell: *Cell(T), io: std.Io };
    const Forward = struct {
        fn produce(context: Context, output: *streams.Stream(Pair)) !void {
            var cursor = sequences.cursor(context.input);
            while (true) {
                try context.io.checkCancel();
                const item = (try cursor.nextOutcome()) orelse return;
                const event = switch (item) {
                    .value => |event| event,
                    .failure => |err| {
                        try output.pushOutcome(.{ .failure = err });
                        continue;
                    },
                };
                const snapshot = try context.cell.snapshot();
                try context.io.checkCancel();
                try output.push(.{ event, snapshot.value });
            }
        }
    };
    return streams.Stream(Pair).initProducer(allocator, io, 1, Forward.produce, Context{ .input = input, .cell = cell, .io = io });
}
