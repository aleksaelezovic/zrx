const std = @import("std");
const composition = @import("composition.zig");
const sequences = @import("sequences.zig");
const runtime = @import("streams.zig");

/// A non-owning description. Only run creates storage or starts the producer.
/// Refer to the same stable declaration by pointer to share an execution node.
pub fn Stream(comptime T: type) type {
    if (@sizeOf(T) == 0) @compileError("Stream: zero-sized elements are not supported");
    return struct {
        const Self = @This();
        pub const sequence_tag = sequences.SequenceTag;
        pub const graph_tag = sequences.GraphTag;
        pub const Item = T;
        capacity: usize,
        produce: *const fn (?*const anyopaque, *Emitter(T)) anyerror!void,
        capability: ?*const anyopaque = null,

        pub fn fromProducer(capacity: usize, comptime producer: anytype) Self {
            return describe(capacity, producer, {}, false);
        }

        /// Borrow an explicitly typed capability pointer; never allocate a copy.
        /// The referent must outlive run and any concurrent use must be safe.
        pub fn fromProducerWith(capacity: usize, comptime producer: anytype, capability: anytype) Self {
            return describe(capacity, producer, capability, true);
        }

        fn describe(capacity: usize, comptime producer: anytype, capability: anytype, comptime with_capability: bool) Self {
            const name = if (with_capability) "Stream.fromProducerWith" else "Stream.fromProducer";
            const info = composition.callbackInfo(producer, name ++ ": producer", if (with_capability) 2 else 1);
            if (info.param_types[if (with_capability) 1 else 0] != *Emitter(T))
                @compileError(name ++ ": producer must accept " ++
                    (if (with_capability) "a capability pointer followed by *Emitter(T)" else "*Emitter(T)"));
            const Return = info.return_type.?;
            if (Return != void and
                (@typeInfo(Return) != .error_union or composition.Payload(Return) != void))
                @compileError(name ++ ": producer must return void or E!void");
            const Capability = if (with_capability) info.param_types[0].? else void;
            if (with_capability and (@typeInfo(Capability) != .pointer or @typeInfo(Capability).pointer.size != .one))
                @compileError(name ++ ": capability must be a single-item pointer");
            const Invoke = struct {
                fn call(context: ?*const anyopaque, output: *Emitter(T)) anyerror!void {
                    const result = if (with_capability)
                        producer(@as(Capability, @ptrCast(@alignCast(@constCast(context.?)))), output)
                    else
                        producer(output);
                    if (Return != void) try result;
                }
            };
            return .{
                .capacity = capacity,
                .produce = Invoke.call,
                .capability = if (with_capability) @ptrCast(@as(Capability, capability)) else null,
            };
        }
    };
}

// Package-internal lowering. Only the execution scope owns the returned queue.
pub fn instantiate(definition: anytype, allocator: std.mem.Allocator, io: std.Io) !runtime.Stream(@TypeOf(definition).Item) {
    const Definition = @TypeOf(definition);
    const T = Definition.Item;
    const Context = struct { definition: Definition, allocator: std.mem.Allocator, io: std.Io };
    const Forward = struct {
        fn start(context: Context, output: *runtime.Stream(T)) anyerror!void {
            var emitter: Emitter(T) = .{
                .io = context.io,
                .allocator = context.allocator,
                .context = output,
            };
            try context.definition.produce(context.definition.capability, &emitter);
        }
    };
    return runtime.Stream(T).fromProducerWith(allocator, io, definition.capacity, Forward.start, Context{
        .definition = definition,
        .allocator = allocator,
        .io = io,
    });
}

/// Borrowed only for the producer call. Cannot be saved or used after return.
/// Return closes output automatically; this handle has no close/deinit methods.
pub fn Emitter(comptime T: type) type {
    return struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        context: *anyopaque,

        pub fn push(self: *@This(), value: T) (std.Io.QueueClosedError || std.Io.Cancelable)!void {
            const output: *runtime.Stream(T) = @ptrCast(@alignCast(self.context));
            try output.push(value);
        }
    };
}
