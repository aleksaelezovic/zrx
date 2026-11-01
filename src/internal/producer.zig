//! Typed producer binding. The dependency environment stays run-local; no
//! callback pointer or separate capability-taking declaration API is needed.
const std = @import("std");
const seq = @import("../data/sequences.zig");
const Emitter = @import("../data/streams.zig").Emitter;
const callbacks = @import("callbacks.zig");
const transport = @import("runtime/streams.zig");

pub fn Bound(comptime T: type, comptime Env: type, comptime callback: anytype) type {
    return struct {
        pub const sequence_tag = seq.SequenceTag;
        pub const graph_tag = seq.GraphTag;
        pub const producer_source = true;
        pub const Item = T;
        capacity: usize,
        env: *Env,

        pub fn instantiate(self: @This(), allocator: std.mem.Allocator, io: std.Io) !transport.Stream(T) {
            const Context = struct { env: *Env, allocator: std.mem.Allocator, io: std.Io };
            const Forward = struct {
                fn produce(context: Context, output: *transport.Stream(T)) !void {
                    var emitter: Emitter(T) = .{ .allocator = context.allocator, .io = context.io, .context = output };
                    const result = callbacks.invoke(callback, context.env, .{&emitter});
                    if (@typeInfo(@TypeOf(result)) == .error_union) try result;
                }
            };
            return transport.Stream(T).initProducer(allocator, io, self.capacity, Forward.produce, Context{
                .env = self.env,
                .allocator = allocator,
                .io = io,
            });
        }
    };
}
