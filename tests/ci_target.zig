//! CI diagnostics only: report Zig's resolved native CPU, not just its triple.
const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const query = std.Target.Query.fromTarget(&builtin.target);
    const triple = try query.zigTriple(allocator);
    defer allocator.free(triple);
    const cpu = try query.serializeCpuAlloc(allocator);
    defer allocator.free(cpu);
    std.debug.print("Zig native target: {s}\nZig native CPU: {s}\n", .{ triple, cpu });
}
