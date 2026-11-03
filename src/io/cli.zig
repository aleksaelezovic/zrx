//! Process argument ownership, not a command-line parser or ambient process API.
const std = @import("std");
const builtin = @import("builtin");
const resource = @import("../internal/world/resources.zig").resource;

/// Immutable run-scoped argv view. Includes argv[0], if present; no token,
/// flag, encoding, or command interpretation is performed here. Tests may
/// supply a borrowed *Arguments with ordinary slice-backed values instead.
pub const Arguments = struct { values: []const []const u8 };

const Storage = struct {
    view: Arguments,
    arena: std.heap.ArenaAllocator,
};

/// Cold managed recipe providing *Arguments. Explicit std.process.Args supplies
/// process capabilities. Uses the run allocator for platform conversion/storage;
/// referents from the supplied native argv must stay valid through run.
/// Selected acquisition/conversion failures remain execution control. Release
/// follows all dependent users. Unselected recipes perform no work.
pub fn arguments(args: std.process.Args) @TypeOf(resource(args, acquire, release)) {
    if (builtin.os.tag == .freestanding)
        @compileError("process arguments require a hosted target");
    return resource(args, acquire, release);
}

fn acquire(allocator: std.mem.Allocator, args: std.process.Args) !*Arguments {
    const storage = try allocator.create(Storage);
    errdefer allocator.destroy(storage);
    storage.* = .{ .view = undefined, .arena = .init(allocator) };
    errdefer storage.arena.deinit();
    storage.view = .{ .values = try args.toSlice(storage.arena.allocator()) };
    return &storage.view;
}

fn release(allocator: std.mem.Allocator, args: *Arguments) void {
    const storage: *Storage = @fieldParentPtr("view", args);
    storage.arena.deinit();
    allocator.destroy(storage);
}
