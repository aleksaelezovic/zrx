const std = @import("std");
const composition = @import("../composition.zig");
const sequences = @import("../../data/sequences.zig");
const broadcast = @import("broadcast.zig");
const queueNext = @import("../queue.zig").next;

// Live transport is private; the public producer description is data/streams.zig.
/// Own a bounded queue, captured capabilities, and an optional lazy producer.
/// Not copyable. Finish borrowed consumer uses before deinit.
pub fn Stream(comptime T: type) type {
    if (@sizeOf(T) == 0) @compileError("Stream: zero-sized elements are not supported by std.Io.Queue");
    return struct {
        const Self = @This();
        const Buffer = broadcast.Buffer(T);
        const Retirement = struct {
            context: *anyopaque,
            inputs: *const fn (*anyopaque) void,
            unused: *const fn (*anyopaque) void,
        };
        pub const sequence_tag = sequences.SequenceTag;
        pub const Item = T;
        const State = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            buffer: []T,
            rendezvous: std.Io.Queue(T),
            buffer_state: Buffer,
            producer: ?*const fn (?*anyopaque, *Self) anyerror!void = null,
            capability: ?*anyopaque = null,
            free_capability: ?*const fn (std.mem.Allocator, *anyopaque) void = null,
            task: ?std.Io.Future(anyerror!void) = null,
            start_mutex: std.Io.Mutex = .init,
            result_mutex: std.Io.Mutex = .init,
            attempted_start: bool = false,
            stopped: bool = false,
            start_error: ?std.Io.ConcurrentError = null,
            external_error: ?anyerror = null,
            retirement: ?Retirement = null,
        };
        state: *State,

        /// Allocate fixed-capacity storage. Capacity zero is a rendezvous channel.
        pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) std.mem.Allocator.Error!Self {
            const state = try allocator.create(State);
            errdefer allocator.destroy(state);
            const buffer = try allocator.alloc(T, capacity);
            state.* = .{
                .allocator = allocator,
                .io = io,
                .buffer = buffer,
                .rendezvous = .init(buffer[0..0]),
                .buffer_state = .{ .io = io, .storage = buffer },
            };
            state.buffer_state.activate();
            return .{ .state = state };
        }

        /// Save a comptime-known producer. Only the first next starts its task.
        /// Returning closes the stream; accepted items drain before its error/end.
        pub fn fromProducer(
            allocator: std.mem.Allocator,
            io: std.Io,
            capacity: usize,
            comptime producer: anytype,
        ) std.mem.Allocator.Error!Self {
            return producerStream(allocator, io, capacity, producer, {}, false);
        }

        /// As fromProducer, copying an explicit capability passed before output.
        /// Constructor order is producer, capability; referenced resources stay borrowed.
        pub fn fromProducerWith(
            allocator: std.mem.Allocator,
            io: std.Io,
            capacity: usize,
            comptime producer: anytype,
            capability: anytype,
        ) std.mem.Allocator.Error!Self {
            return producerStream(allocator, io, capacity, producer, capability, true);
        }

        fn producerStream(
            allocator: std.mem.Allocator,
            io: std.Io,
            capacity: usize,
            comptime producer: anytype,
            capability: anytype,
            comptime with_capability: bool,
        ) std.mem.Allocator.Error!Self {
            const name = if (with_capability) "Stream.fromProducerWith" else "Stream.fromProducer";
            const info = composition.callbackInfo(producer, name ++ ": producer", if (with_capability) 2 else 1);
            if (info.param_types[if (with_capability) 1 else 0] != *Self)
                @compileError(name ++ ": producer must accept " ++
                    (if (with_capability) "a capability followed by *Stream(T)" else "*Stream(T)"));
            const Return = info.return_type.?;
            if (Return != void and
                (@typeInfo(Return) != .error_union or composition.Payload(Return) != void))
                @compileError(name ++ ": producer must return void or E!void");
            const Capability = if (with_capability) info.param_types[0].? else void;
            const Invoke = struct {
                fn call(context: ?*anyopaque, output: *Self) anyerror!void {
                    const result = if (with_capability)
                        producer(@as(*Capability, @ptrCast(@alignCast(context.?))).*, output)
                    else
                        producer(output);
                    if (Return != void) try result;
                }

                fn free(gpa: std.mem.Allocator, context: *anyopaque) void {
                    gpa.destroy(@as(*Capability, @ptrCast(@alignCast(context))));
                }
            };
            var self = try init(allocator, io, capacity);
            errdefer self.deinit();
            if (with_capability) {
                const stored = try allocator.create(Capability);
                stored.* = capability;
                self.state.capability = @ptrCast(stored);
                self.state.free_capability = Invoke.free;
            }
            self.state.producer = Invoke.call;
            return self;
        }

        /// Cancel/join the owned producer, then free internal storage.
        /// Never starts a cold producer; does not own external tasks or payload referents.
        pub fn deinit(self: *Self) void {
            self.state.buffer_state.assertDeinit();
            if (self.state.task) |*task| task.cancel(self.state.io) catch {};
            const allocator = self.state.allocator;
            if (self.state.free_capability) |free| free(allocator, self.state.capability.?);
            allocator.free(self.state.buffer);
            allocator.destroy(self.state);
            self.* = undefined;
        }

        /// Accept one item, waiting for capacity. Does not run downstream pipelines.
        pub fn push(self: *Self, value: T) (std.Io.QueueClosedError || std.Io.Cancelable)!void {
            if (self.state.buffer.len == 0) {
                try self.state.rendezvous.putOne(self.state.io, value);
            } else {
                try self.state.buffer_state.push(value);
            }
        }

        /// Idempotent. Buffered values drain before readers observe end.
        /// Positive-capacity writes commit before close or fail without publication.
        pub fn close(self: *Self) void {
            self.state.start_mutex.lockUncancelable(self.state.io);
            defer self.state.start_mutex.unlock(self.state.io);
            self.state.stopped = true;
            self.state.buffer_state.close();
            if (self.state.buffer.len == 0) self.state.rendezvous.close(self.state.io);
        }

        // Run alone owns these edges; borrowed low-level stream adapters do not
        // gain ownership of their input. Install only during graph preparation.
        pub fn setRetirement(self: *Self, context: *anyopaque, inputs: *const fn (*anyopaque) void, unused: *const fn (*anyopaque) void) void {
            self.state.retirement = .{ .context = context, .inputs = inputs, .unused = unused };
        }

        // Internal externally driven publishers (signal values) carry an outer
        // execution error even though they have no owned producer future.
        pub fn fail(self: *Self, err: anyerror) void {
            self.state.result_mutex.lockUncancelable(self.state.io);
            if (self.state.external_error == null) self.state.external_error = err;
            self.state.result_mutex.unlock(self.state.io);
            self.close();
        }

        /// Borrow consuming state without starting production or reading an item.
        pub fn iterator(self: *Self) Iterator {
            return .{ .state = self.state, .record = &self.state.buffer_state.original };
        }

        pub const Iterator = struct {
            state: *State,
            record: *Buffer.Record,

            pub fn next(self: *@This()) anyerror!?T {
                try self.state.buffer_state.beginRead(self.record);
                defer self.state.buffer_state.endRead(self.record);
                try startProducer(self.state);
                if (self.state.buffer.len == 0) {
                    if (try queueNext(T, self.state.io, &self.state.rendezvous)) |value|
                        return @as(?T, value);
                    try self.awaitProducer();
                    return null;
                }
                if (try self.state.buffer_state.next(self.record)) |value|
                    return @as(?T, value);
                try self.awaitProducer();
                return null;
            }

            fn awaitProducer(self: *@This()) !void {
                try self.state.buffer_state.awaitProducer(self.record);
                // No user callback remains after the cancellable completion wait.
                try self.state.result_mutex.lock(self.state.io);
                defer self.state.result_mutex.unlock(self.state.io);
                if (self.state.external_error) |err| return err;
                if (self.state.task) |*task| try task.await(self.state.io);
            }
        };

        /// An owning read claim. Its stream must outlive it; copies alias ownership.
        pub const Reader = struct {
            pub const sequence_tag = sequences.SequenceTag;
            pub const Item = T;
            pub const Iterator = Self.Iterator;
            state: *State,
            record: *Buffer.Record,

            pub fn iterator(self: *@This()) Self.Iterator {
                return .{ .state = self.state, .record = self.record };
            }

            /// Fork the next unread position without running callbacks.
            pub fn clone(self: *@This()) broadcast.BranchError!@This() {
                return .{ .state = self.state, .record = try self.state.buffer_state.clone(self.state.allocator, self.record) };
            }

            /// Detach, release retention, and wake this reader's pending next calls.
            pub fn close(self: *@This()) void {
                if (self.state.buffer_state.detach(self.record)) {
                    var owner: Self = .{ .state = self.state };
                    owner.close();
                    if (self.state.retirement) |retirement| retirement.unused(retirement.context);
                }
            }

            /// No consumer operation may still be using this handle or its cursors.
            pub fn deinit(self: *@This()) void {
                self.close();
                self.state.buffer_state.destroy(self.state.allocator, self.record);
                self.* = undefined;
            }
        };

        pub const Split = struct {
            left: Reader,
            right: Reader,

            /// Join consumer tasks before freeing their readers. Do not separately
            /// deinit the fields; closing either field early is allowed.
            pub fn deinit(self: *@This()) void {
                self.left.deinit();
                self.right.deinit();
                self.* = undefined;
            }
        };

        fn split(self: *Self) broadcast.BranchError!Split {
            const records = try self.state.buffer_state.split(self.state.allocator);
            return .{
                .left = .{ .state = self.state, .record = records.left },
                .right = .{ .state = self.state, .record = records.right },
            };
        }

        fn startProducer(state: *State) !void {
            if (state.producer == null) return;
            try state.start_mutex.lock(state.io);
            defer state.start_mutex.unlock(state.io);
            if (state.start_error) |err| return err;
            if (state.attempted_start or state.stopped) return;
            state.attempted_start = true;
            state.buffer_state.producerPending(true);
            // async may run inline and deadlock on a full queue; concurrent must
            // provide independent progress or explicitly fail to start.
            state.task = state.io.concurrent(runProducer, .{state}) catch |err| {
                state.start_error = err;
                state.stopped = true;
                state.buffer_state.producerPending(false);
                state.buffer_state.close();
                if (state.buffer.len == 0) state.rendezvous.close(state.io);
                return err;
            };
        }

        fn runProducer(state: *State) anyerror!void {
            var output: Self = .{ .state = state };
            const result = state.producer.?(state.capability, &output);
            if (state.retirement) |retirement| retirement.inputs(retirement.context);
            output.close();
            state.buffer_state.producerPending(false);
            return result;
        }
    };
}

/// Materialize one lazy input evaluation into an owned, bounded stream.
/// The input remains borrowed; only first output consumption starts forwarding.
pub fn share(
    allocator: std.mem.Allocator,
    io: std.Io,
    capacity: usize,
    input: anytype,
) (std.mem.Allocator.Error || error{UnsupportedCapacity})!Stream(sequences.Item(@TypeOf(input))) {
    if (capacity == 0) return error.UnsupportedCapacity;
    const Input = @TypeOf(input);
    const Element = sequences.Item(Input);
    const Context = struct { input: Input, io: std.Io };
    const Forward = struct {
        fn produce(context: Context, output: *Stream(Element)) anyerror!void {
            var cursor = sequences.cursor(context.input);
            while (true) {
                // A ready input/output may not otherwise reach a blocking cancel point.
                try context.io.checkCancel();
                const value = (if (comptime sequences.isFallible(Input)) try cursor.next() else cursor.next()) orelse return;
                try context.io.checkCancel();
                try output.push(value);
            }
        }
    };
    return Stream(Element).fromProducerWith(allocator, io, capacity, Forward.produce, Context{ .input = input, .io = io });
}

/// Run-owned recurrence, never exposed as a mutable public cursor. Output slots
/// receive shallow values, not references into the worker's accumulator.
pub fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    capacity: usize,
    input: anytype,
    initial: anytype,
    comptime reducer: anytype,
) (std.mem.Allocator.Error || error{UnsupportedCapacity})!Stream(@TypeOf(initial)) {
    if (capacity == 0) return error.UnsupportedCapacity;
    const Input = @TypeOf(input);
    const State = @TypeOf(initial);
    const Context = struct { input: Input, initial: State, io: std.Io };
    const Forward = struct {
        fn produce(context: Context, output: *Stream(State)) anyerror!void {
            var cursor = sequences.cursor(context.input);
            var state = context.initial;
            while (true) {
                try context.io.checkCancel();
                const value = (if (comptime sequences.isFallible(Input)) try cursor.next() else cursor.next()) orelse return;
                state = reducer(state, value);
                try context.io.checkCancel();
                try output.push(state);
            }
        }
    };
    return Stream(State).fromProducerWith(allocator, io, capacity, Forward.produce, Context{
        .input = input,
        .initial = initial,
        .io = io,
    });
}

/// Run-owned retention. Allocate the ring during graph preparation, not on pull.
/// Input and payload referents stay borrowed; only the shallow ring is owned here.
pub fn takeLast(
    allocator: std.mem.Allocator,
    io: std.Io,
    capacity: usize,
    input: anytype,
    limit: usize,
) (std.mem.Allocator.Error || error{UnsupportedCapacity})!Stream(sequences.Item(@TypeOf(input))) {
    if (capacity == 0) return error.UnsupportedCapacity;
    const Input = @TypeOf(input);
    const Element = sequences.Item(Input);
    const Context = struct { input: Input, io: std.Io, storage: []Element };
    const Forward = struct {
        fn produce(context: Context, output: *Stream(Element)) anyerror!void {
            var cursor = sequences.cursor(context.input);
            var count: usize = 0;
            var next: usize = 0;
            while (true) {
                try context.io.checkCancel();
                const value = (if (comptime sequences.isFallible(Input)) try cursor.next() else cursor.next()) orelse break;
                if (context.storage.len == 0) continue;
                context.storage[next] = value;
                next = if (next == context.storage.len - 1) 0 else next + 1;
                if (count < context.storage.len) count += 1;
            }
            try context.io.checkCancel();
            var index: usize = if (count == context.storage.len) next else 0;
            for (0..count) |_| {
                try context.io.checkCancel();
                try output.push(context.storage[index]);
                index = if (index == context.storage.len - 1) 0 else index + 1;
            }
        }

        fn free(gpa: std.mem.Allocator, opaque_context: *anyopaque) void {
            const context: *Context = @ptrCast(@alignCast(opaque_context));
            gpa.free(context.storage);
            gpa.destroy(context);
        }
    };
    const storage = try allocator.alloc(Element, limit);
    errdefer allocator.free(storage);
    const owner = try Stream(Element).fromProducerWith(allocator, io, capacity, Forward.produce, Context{
        .input = input,
        .io = io,
        .storage = storage,
    });
    // Unlike ordinary borrowed producer capabilities, this context owns its ring.
    // Owner deinit runs this cleanup after canceling/joining the producer.
    owner.state.free_capability = Forward.free;
    return owner;
}

/// Run-owned fan-in over already registered homogeneous reader pointers.
/// Its context copies the pointer array, not the input readers or their ownership.
pub fn merge(
    allocator: std.mem.Allocator,
    io: std.Io,
    capacity: usize,
    inputs: anytype,
) (std.mem.Allocator.Error || error{UnsupportedCapacity})!Stream(sequences.Item(@typeInfo(@TypeOf(inputs)).array.child)) {
    if (capacity == 0) return error.UnsupportedCapacity;
    const Inputs = @TypeOf(inputs);
    const Element = sequences.Item(@typeInfo(Inputs).array.child);
    const Context = struct { inputs: Inputs, io: std.Io };
    const Forward = struct {
        fn produce(context: Context, output: *Stream(Element)) anyerror!void {
            var state: MergeExecution = .{ .io = context.io, .remaining = context.inputs.len };
            var group: std.Io.Group = .init;
            defer group.cancel(context.io);
            for (context.inputs) |reader| {
                // The gate prevents input work until every forwarder exists.
                // Startup failure returns directly; deferred cancellation joins
                // the already-created waiters without replacing that error.
                try group.concurrent(context.io, worker, .{ &state, reader, output });
            }
            try context.io.checkCancel();
            state.armed.set(context.io);
            state.done.wait(context.io) catch |err| return state.failure() orelse err;
            if (state.failure()) |err| return err;
            try group.await(context.io);
        }

        fn worker(state: *MergeExecution, reader: *Stream(Element).Reader, output: *Stream(Element)) void {
            const result = copy(state, reader, output);
            state.finish(result);
        }

        fn copy(state: *MergeExecution, reader: *Stream(Element).Reader, output: *Stream(Element)) !void {
            try state.armed.wait(state.io);
            var cursor = reader.iterator();
            while (true) {
                try state.io.checkCancel();
                const value = (try cursor.next()) orelse return;
                try state.io.checkCancel();
                try output.push(value);
            }
        }
    };
    return Stream(Element).fromProducerWith(allocator, io, capacity, Forward.produce, Context{ .inputs = inputs, .io = io });
}

const MergeExecution = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    armed: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    remaining: usize,
    first_error: ?anyerror = null,

    fn finish(self: *@This(), result: anyerror!void) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        result catch |err| {
            if (self.first_error == null) self.first_error = err;
        };
        self.remaining -= 1;
        if (self.first_error != null or self.remaining == 0) self.done.set(self.io);
    }

    fn failure(self: *@This()) ?anyerror {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.first_error;
    }
};

/// Replace the default read position with two independent owning readers.
/// Positive capacity and a quiescent default reader are required; no producer starts.
pub fn tee(stream: anytype) broadcast.BranchError!Owner(@TypeOf(stream)).Split {
    return stream.split();
}

fn Owner(comptime Pointer: type) type {
    const contract = "tee: expected a mutable pointer to Stream(T)";
    if (@typeInfo(Pointer) != .pointer or @typeInfo(Pointer).pointer.size != .one or
        @typeInfo(Pointer).pointer.attrs.@"const") @compileError(contract);
    const Source = @typeInfo(Pointer).pointer.child;
    if (@typeInfo(Source) != .@"struct" or !@hasDecl(Source, "Item")) @compileError(contract);
    if (Source != Stream(Source.Item)) @compileError(contract);
    return Source;
}

// Package-internal stop/join, also used by last-reader retirement during run.
// Storage destruction still waits until all reader/cursor users have joined.
pub fn stopProducer(source: anytype) void {
    source.close();
    // Reader retirement may race a completed reader's Future.await or another
    // retirement. Futures are not threadsafe; serialize all joins of this task.
    source.state.result_mutex.lockUncancelable(source.state.io);
    defer source.state.result_mutex.unlock(source.state.io);
    if (source.state.task) |*task| task.cancel(source.state.io) catch {};
}
