const std = @import("std");
const jobs = @import("domain/jobs.zig");

/// Application-owned, single-lane store. No concurrent access or eviction.
/// The managed recipe owns it through all graph users.
/// Tests may instead lend a caller-owned *Store and inspect it after joining.
pub const Store = struct {
    records: []jobs.Record,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Store {
        return .{ .records = try allocator.alloc(jobs.Record, capacity) };
    }

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
        self.* = undefined;
    }

    pub fn submit(self: *Store, job: jobs.Job) error{StoreFull}!jobs.Record {
        if (self.len == self.records.len) return error.StoreFull;
        const record: jobs.Record = .{ .id = @intCast(self.len + 1), .job = job };
        self.records[self.len] = record;
        self.len += 1;
        return record;
    }

    pub fn lookup(self: *const Store, id: u64) error{NotFound}!jobs.Record {
        if (id == 0 or id > self.len) return error.NotFound;
        return self.records[@intCast(id - 1)];
    }
};
