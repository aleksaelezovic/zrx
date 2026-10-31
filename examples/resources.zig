//! Two roles backed by separate run-owned in-memory databases.
//! No database driver or network access is needed.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const fromSlice = zrx.fromSlice;
const each = zrx.each;
const forEach = zrx.forEach;
const resource = zrx.resource;
const deriveResource = zrx.deriveResource;
const run = zrx.run;

pub const PrimaryDatabase = struct { value: *Database };
pub const AuditDatabase = struct { value: *Database };
pub const Report = struct {
    primary_total: u64 = 0,
    audit_total: u64 = 0,
    acquired: usize = 0,
    released: usize = 0,
};
pub const Database = struct {
    kind: enum { primary, audit },
    scale: u32,
    total: u64 = 0,
};
pub const Configuration = struct {
    kind: @FieldType(Database, "kind"),
    scale: u32,
};
fn open(allocator: std.mem.Allocator, io: std.Io, report: *Report, config: Configuration) !*Database {
    try io.checkCancel();
    const instance = try allocator.create(Database);
    instance.* = .{ .kind = config.kind, .scale = config.scale };
    report.acquired += 1;
    return instance;
}

fn close(allocator: std.mem.Allocator, report: *Report, instance: *Database) void {
    switch (instance.kind) {
        .primary => report.primary_total = instance.total,
        .audit => report.audit_total = instance.total,
    }
    report.released += 1;
    allocator.destroy(instance);
}

pub fn database(config: Configuration) @TypeOf(resource(config, open, close)) {
    return resource(config, open, close);
}

fn transform(database_role: PrimaryDatabase, value: u32) u64 {
    database_role.value.total += value;
    return @as(u64, value) * database_role.value.scale;
}

fn record(database_role: AuditDatabase, value: u64) void {
    database_role.value.total += value;
}

/// Construction is cold; input is borrowed until run completes.
pub fn program(input: []const u32) @TypeOf(pipe(fromSlice(input), .{ each(transform), forEach(record) })) {
    return pipe(fromSlice(input), .{ each(transform), forEach(record) });
}

pub fn main(init: std.process.Init) !void {
    var report: Report = .{};
    // Deliberately put services before bootstrap bindings; tuple order is not
    // acquisition order. Both roles privately own a configured database recipe.
    try run(.{
        deriveResource(AuditDatabase, database(.{ .kind = .audit, .scale = 1 })),
        &report,
        deriveResource(PrimaryDatabase, database(.{ .kind = .primary, .scale = 2 })),
        init.io,
        init.gpa,
    }, .{program(&.{ 1, 2, 3 })});
    std.debug.print("Resources: primary={d} audit={d} acquired={d} released={d}\n", .{
        report.primary_total, report.audit_total, report.acquired, report.released,
    });
}
