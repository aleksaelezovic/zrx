// Scoped execution of terminal effect declarations over streams and finite inputs.
const std = @import("std");
const composition = @import("internal/composition.zig");
const sequences = @import("data/sequences.zig");
const streams = @import("internal/runtime/streams.zig");
const sources = @import("data/streams.zig");
const merging = @import("ops/merge.zig");
const each = @import("ops/each.zig").each;
const filter = @import("ops/filter.zig").filter;
const maxItems = @import("ops/maxItems.zig").maxItems;
const signal_kind = @import("internal/signal_kind.zig");
const state = @import("internal/runtime/signals.zig");
const resources = @import("internal/resources.zig");
const line_io = @import("io/lines.zig");
const FlowTag = opaque {};

fn isSource(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "graph_tag") and
        T.graph_tag == sequences.GraphTag and T == sources.Stream(T.Item);
}

pub fn Flow(comptime Input: type, comptime Consumer: type) type {
    const Element = sequences.Item(Input);
    return struct {
        pub const flow_tag = FlowTag;
        source: Input,
        consumer: Consumer,
        reader: ?*streams.Stream(Element).Reader = null,

        fn prepare(self: *@This(), scope: *Scope) !void {
            try self.consumer.prepare(scope.allocator);
            const node = try resolve(scope, &self.source);
            self.reader = try node.acquire(scope.allocator);
            if (@hasDecl(Consumer, "prepareResources"))
                try self.consumer.prepareResources(&scope.resources);
        }

        fn execute(self: *@This(), allocator: std.mem.Allocator, io: std.Io) !void {
            try self.consumer.consume(self.reader.?, allocator, io);
        }

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.consumer.deinit(allocator);
        }
    };
}

/// Register every selected reader before activating any terminal effect flow.
/// Collected storage is scoped to callbacks, not returned as an owned result.
/// Accept a nonempty flat tuple of terminal flow declarations. This is the
/// allocation, activation, cancellation, and cleanup boundary for both finite
/// and stream-backed inputs. It supplies allocator/Io, not domain services.
///
/// Stable pointer references share address-and-type identity within one run;
/// by-value descriptions are independent. Only reachable nodes activate. Each
/// selected edge gets its own reader; unselected declarations pin no buffer.
/// Preserve input order; independent nodes/effects can execute concurrently.
/// Descriptions must stay valid/unmodified, capability referents alive and safe
/// for concurrent use. Each new run creates fresh state and calls producers again.
///
/// Run owns queues/readers/workers, terminal buffers, and signal caches. It joins
/// consumers before freeing buffers, stops state updaters before transport,
/// stops derived workers before producers, and frees caches after samplers join.
/// Preparation/consumer/state-worker startup failure activates no producer or
/// initial maps. Merge's local startup happens after activation: peers may have
/// worked. First observed failure cancels peers without rollback; cleanup
/// cancellation cannot replace the chosen result.
///
/// High-level line I/O resources are acquired after preparation and gated worker
/// startup, before initial maps/data activation. Only selected nodes acquire.
/// Partial acquisition is cleaned up; acquisition can itself create/truncate
/// files/connect and is not rolled back. I/O terminals include flushing in their
/// successful completion. Owned handles close after all users join; process
/// stdio handles remain open. Equal paths do not imply shared resource identity.
///
/// Cancellation is cooperative: blocking/long callbacks must cooperate, and
/// non-returning non-cancelable code cannot be forcibly stopped. Shallow item
/// referents and caller-supplied capabilities remain borrowed, not run-owned.
/// See docs/execution.md and examples/pipes.zig for the cross-operator lifecycle.
pub fn run(allocator: std.mem.Allocator, io: std.Io, flows: anytype) anyerror!void {
    const Flows = @TypeOf(flows);
    if (comptime !composition.isTuple(Flows))
        @compileError("run: expected a nonempty flat tuple of terminal effect flows");
    const count = @typeInfo(Flows).@"struct".field_types.len;
    if (count == 0) @compileError("run: expected a nonempty flat tuple of terminal effect flows");
    inline for (@typeInfo(Flows).@"struct".field_types) |T| {
        if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "flow_tag") or T.flow_tag != FlowTag)
            @compileError("run: expected a nonempty flat tuple of terminal effect flows");
    }
    try io.checkCancel();
    // Literal tuple fields can be comptime-only. Preparation needs ordinary
    // runtime fields for mutable consumer storage and stable worker addresses.
    var definitions: @Tuple(@typeInfo(Flows).@"struct".field_types) = undefined;
    inline for (0..count) |i| definitions[i] = flows[i];
    var scope: Scope = .{
        .allocator = allocator,
        .io = io,
        .resources = .{ .allocator = allocator, .io = io },
    };
    defer scope.deinit();
    defer inline for (0..count) |i| definitions[i].deinit(allocator);
    inline for (0..count) |i| try definitions[i].prepare(&scope);
    for (scope.nodes.items) |node| node.finalize(node.context);

    var execution: Execution = .{ .allocator = allocator, .io = io, .remaining = count };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    inline for (0..count) |i| {
        const Worker = struct {
            fn start(control: *Execution, flow: *@TypeOf(definitions[i])) void {
                const result = work(control, flow);
                control.finish(result);
            }
            fn work(control: *Execution, flow: *@TypeOf(definitions[i])) !void {
                try control.armed.wait(control.io);
                try flow.execute(control.allocator, control.io);
            }
        };
        group.concurrent(io, Worker.start, .{ &execution, &definitions[i] }) catch |err| {
            execution.fail(err);
            return execution.failure().?;
        };
    }
    for (scope.families.items) |family| {
        family.start(&execution.armed, .{
            .context = &execution,
            .fail = Execution.report,
        }) catch |err| {
            execution.fail(err);
            return execution.failure().?;
        };
    }
    try scope.resources.acquireAll();
    for (scope.families.items) |family| try family.initialize();
    try io.checkCancel();
    execution.armed.set(io);
    execution.done.wait(io) catch |err| return execution.failure() orelse err;
    if (execution.failure()) |err| return err;
    try group.await(io);
}

const Execution = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    armed: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    remaining: usize,
    first_error: ?anyerror = null,
    closed: bool = false,

    fn report(context: *anyopaque, err: anyerror) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.fail(err);
    }

    fn fail(self: *@This(), err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return;
        self.first_error = err;
        self.closed = true;
        self.done.set(self.io);
    }

    fn finish(self: *@This(), result: anyerror!void) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        result catch |err| {
            if (!self.closed) {
                self.first_error = err;
                self.closed = true;
            }
        };
        self.remaining -= 1;
        if (self.remaining == 0) self.closed = true;
        if (self.closed) self.done.set(self.io);
    }

    fn failure(self: *@This()) ?anyerror {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.first_error;
    }
};

const Key = struct { address: usize, type_id: usize };
const Node = struct {
    context: *anyopaque,
    finalize: *const fn (*anyopaque) void,
    stop: *const fn (*anyopaque) void,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};

const Scope = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    resources: resources.Scope,
    index: std.AutoHashMapUnmanaged(Key, *Node) = .{},
    nodes: std.ArrayList(*Node) = .empty,
    signal_index: std.AutoHashMapUnmanaged(Key, *state.Entry) = .{},
    families: std.ArrayList(*state.Family) = .empty,

    fn reserve(self: *@This()) !void {
        try self.index.ensureUnusedCapacity(self.allocator, 1);
        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
    }

    fn insert(self: *@This(), key: Key, node: *Node) void {
        self.index.putAssumeCapacity(key, node);
        self.nodes.appendAssumeCapacity(node);
    }

    fn deinit(self: *@This()) void {
        // State updaters publish into stream nodes; samplers read their caches.
        // Stop updaters first, join all stream workers, then dispose caches.
        var family_index = self.families.items.len;
        while (family_index > 0) {
            family_index -= 1;
            self.families.items[family_index].stop();
        }
        // Consumers have already joined. Stop derived workers before upstream
        // sources, then free readers before the owners they borrow.
        var i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const node = self.nodes.items[i];
            node.stop(node.context);
        }
        i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const node = self.nodes.items[i];
            node.destroy(node.context, self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.index.deinit(self.allocator);
        for (self.families.items) |family| family.destroy(self.allocator);
        self.families.deinit(self.allocator);
        self.signal_index.deinit(self.allocator);
        self.resources.deinit();
    }
};

fn Runtime(comptime T: type) type {
    return struct {
        const Self = @This();
        node: Node,
        owner: *streams.Stream(T),
        capacity: usize,
        split: streams.Stream(T).Split,
        used: usize = 0,
        clones: std.ArrayList(*streams.Stream(T).Reader) = .empty,

        fn create(gpa: std.mem.Allocator, owner: *streams.Stream(T), capacity: usize) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const split = try streams.tee(owner);
            self.* = .{
                .node = .{ .context = self, .finalize = finalize, .stop = stop, .destroy = destroy },
                .owner = owner,
                .capacity = capacity,
                .split = split,
            };
            return self;
        }

        fn acquire(self: *Self, gpa: std.mem.Allocator) !*streams.Stream(T).Reader {
            if (self.used < 2) {
                self.used += 1;
                return if (self.used == 1) &self.split.left else &self.split.right;
            }
            const reader = try gpa.create(streams.Stream(T).Reader);
            errdefer gpa.destroy(reader);
            reader.* = try self.split.left.clone();
            errdefer reader.deinit();
            try self.clones.append(gpa, reader);
            self.used += 1;
            return reader;
        }

        fn cast(context: *anyopaque) *Self {
            return @ptrCast(@alignCast(context));
        }
        fn finalize(context: *anyopaque) void {
            const self = cast(context);
            if (self.used == 0) self.split.left.close();
            if (self.used < 2) self.split.right.close();
        }
        fn stop(context: *anyopaque) void {
            streams.stopProducer(cast(context).owner);
        }
        fn destroy(context: *anyopaque, gpa: std.mem.Allocator) void {
            const self = cast(context);
            for (self.clones.items) |reader| {
                reader.deinit();
                gpa.destroy(reader);
            }
            self.clones.deinit(gpa);
            self.split.deinit();
            self.owner.deinit();
            gpa.destroy(self.owner);
            gpa.destroy(self);
        }
    };
}

fn typeId(comptime T: type) usize {
    const Identity = struct {
        const Type = T;
        var byte: u8 = 0;
    };
    return @intFromPtr(&Identity.byte);
}

// The outer pointer refers either to a value stored in a flow/descriptor, or
// to a pointer value which must be followed to preserve the referenced identity.
fn resolve(scope: *Scope, value: anytype) anyerror!*Runtime(sequences.Item(@typeInfo(@TypeOf(value)).pointer.child)) {
    const Input = @typeInfo(@TypeOf(value)).pointer.child;
    if (@typeInfo(Input) == .pointer and @typeInfo(Input).pointer.size == .one)
        return resolveReference(scope, value.*);
    return resolveReference(scope, value);
}

fn ReferenceInput(comptime Pointer: type) type {
    const Child = @typeInfo(Pointer).pointer.child;
    return if (@typeInfo(Child) == .array) Pointer else Child;
}

fn resolveReference(scope: *Scope, reference: anytype) anyerror!*Runtime(sequences.Item(ReferenceInput(@TypeOf(reference)))) {
    const Definition = @typeInfo(@TypeOf(reference)).pointer.child;
    const Input = ReferenceInput(@TypeOf(reference));
    const Element = sequences.Item(Input);
    const root = comptime isSource(Definition);
    const key: Key = .{
        .address = @intFromPtr(reference),
        .type_id = typeId(Definition),
    };
    if (scope.index.get(key)) |node| return @ptrCast(@alignCast(node.context));

    if (comptime line_io.isSource(Definition)) {
        if (reference.capacity == 0) return error.UnsupportedCapacity;
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = try reference.instantiate(&scope.resources);
        errdefer owner.deinit();
        const runtime = try Runtime(Element).create(scope.allocator, owner, reference.capacity);
        scope.insert(key, &runtime.node);
        return runtime;
    } else if (root) {
        if (reference.capacity == 0) return error.UnsupportedCapacity;
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = try sources.instantiate(reference.*, scope.allocator, scope.io);
        errdefer owner.deinit();
        const runtime = try Runtime(Element).create(scope.allocator, owner, reference.capacity);
        scope.insert(key, &runtime.node);
        return runtime;
    } else if (comptime signal_kind.isValues(Definition)) {
        const cell = try resolveSignal(scope, &reference.signal);
        if (cell.observation_node) |existing| return @ptrCast(@alignCast(existing));
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = try streams.Stream(Element).init(scope.allocator, scope.io, 1);
        errdefer owner.deinit();
        const runtime = try Runtime(Element).create(scope.allocator, owner, 1);
        scope.insert(key, &runtime.node);
        cell.observation = owner;
        cell.observation_node = runtime;
        return runtime;
    } else if (comptime signal_kind.isSample(Definition)) {
        const cell = try resolveSignal(scope, &reference.signal);
        const upstream = try resolve(scope, &reference.source);
        const reader = try upstream.acquire(scope.allocator);
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = try state.sample(scope.allocator, scope.io, reader, signal_kind.Value(@TypeOf(reference.signal)), cell);
        errdefer owner.deinit();
        const runtime = try Runtime(Element).create(scope.allocator, owner, 1);
        scope.insert(key, &runtime.node);
        return runtime;
    } else if (comptime merging.isMerge(Definition)) {
        const count = @typeInfo(@TypeOf(reference.inputs)).@"struct".field_types.len;
        var readers: [count]*streams.Stream(Element).Reader = undefined;
        inline for (0..count) |i| {
            const upstream = try resolve(scope, &reference.inputs[i]);
            readers[i] = try upstream.acquire(scope.allocator);
        }
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = try streams.merge(scope.allocator, scope.io, 1, readers);
        errdefer owner.deinit();
        const runtime = try Runtime(Element).create(scope.allocator, owner, 1);
        scope.insert(key, &runtime.node);
        return runtime;
    } else if (comptime @typeInfo(Definition) == .@"struct" and @hasDecl(Definition, "declaration_source")) {
        const upstream = try resolve(scope, &reference.source);
        const reader = try upstream.acquire(scope.allocator);
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = if (Definition.declaration_kind == .retained)
            try streams.takeLast(scope.allocator, scope.io, upstream.capacity, reader, reference.limit)
        else block: {
            const view = if (Definition.declaration_kind == .mapped)
                each(Definition.declaration_functions).apply(reader)
            else if (Definition.declaration_kind == .filtered)
                filter(Definition.declaration_predicate).apply(reader)
            else if (Definition.declaration_kind == .bounded)
                maxItems(reference.limit).apply(reader)
            else
                @compileError("run: unsupported declaration kind");
            break :block try streams.share(scope.allocator, scope.io, upstream.capacity, view);
        };
        errdefer owner.deinit();
        const runtime = try Runtime(Element).create(scope.allocator, owner, upstream.capacity);
        scope.insert(key, &runtime.node);
        return runtime;
    } else {
        // Conventional sources are borrowed. Referenced finite sources/views
        // participate in the same sharing/lifecycle rules as declared streams.
        const input = if (@typeInfo(Definition) == .array) reference else reference.*;
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = try streams.share(scope.allocator, scope.io, 1, input);
        errdefer owner.deinit();
        const runtime = try Runtime(Element).create(scope.allocator, owner, 1);
        scope.insert(key, &runtime.node);
        return runtime;
    }
}

fn resolveSignal(scope: *Scope, value: anytype) anyerror!*state.Cell(signal_kind.Value(@typeInfo(@TypeOf(value)).pointer.child)) {
    const Input = @typeInfo(@TypeOf(value)).pointer.child;
    if (@typeInfo(Input) == .pointer and @typeInfo(Input).pointer.size == .one)
        return resolveSignalReference(scope, value.*);
    return resolveSignalReference(scope, value);
}

fn resolveSignalReference(scope: *Scope, reference: anytype) anyerror!*state.Cell(signal_kind.Value(@TypeOf(reference))) {
    const Definition = @typeInfo(@TypeOf(reference)).pointer.child;
    const T = signal_kind.Value(@TypeOf(reference));
    const key: Key = .{ .address = @intFromPtr(reference), .type_id = typeId(Definition) };
    if (scope.signal_index.get(key)) |entry| return state.Cell(T).cast(entry);
    if (Definition.signal_kind == .root) {
        const upstream = try resolve(scope, &reference.source);
        const reader = try upstream.acquire(scope.allocator);
        try scope.signal_index.ensureUnusedCapacity(scope.allocator, 1);
        try scope.families.ensureUnusedCapacity(scope.allocator, 1);
        const family = try scope.allocator.create(state.Family);
        errdefer scope.allocator.destroy(family);
        family.* = .{ .io = scope.io, .context = undefined, .drive = state.Cell(T).driveRoot };
        errdefer family.entries.deinit(scope.allocator);
        const cell = try state.Cell(T).create(scope.allocator, family);
        errdefer scope.allocator.destroy(cell);
        cell.candidate = reference.initial;
        cell.updates = reader;
        family.context = cell;
        try family.entries.append(scope.allocator, &cell.entry);
        scope.families.appendAssumeCapacity(family);
        scope.signal_index.putAssumeCapacity(key, &cell.entry);
        return cell;
    } else {
        const parent = try resolveSignal(scope, &reference.source);
        const P = signal_kind.Value(@TypeOf(reference.source));
        try scope.signal_index.ensureUnusedCapacity(scope.allocator, 1);
        try parent.family.entries.ensureUnusedCapacity(scope.allocator, 1);
        const cell = try state.Cell(T).create(scope.allocator, parent.family);
        const Compute = struct {
            fn candidate(entry: *state.Entry) void {
                const target = state.Cell(T).cast(entry);
                const input = state.Cell(P).cast(entry.parent.?);
                target.candidate = composition.compose(input.candidate, Definition.signal_functions, 0);
            }
        };
        cell.entry.parent = &parent.entry;
        cell.entry.compute = Compute.candidate;
        parent.family.entries.appendAssumeCapacity(&cell.entry);
        scope.signal_index.putAssumeCapacity(key, &cell.entry);
        return cell;
    }
}
