// Scoped execution of terminal effect declarations over streams and finite inputs.
const std = @import("std");
const composition = @import("composition.zig");
const sequences = @import("../data/sequences.zig");
const streams = @import("runtime/streams.zig");
const sources = @import("../data/streams.zig");
const merging = @import("../ops/merge.zig");
const each = @import("../ops/each.zig").each;
const filter = @import("../ops/filter.zig").filter;
const maxItems = @import("../ops/maxItems.zig").maxItems;
const take = @import("../ops/take.zig").take;
const signal_kind = @import("signal_kind.zig");
const state = @import("runtime/signals.zig");
const resources = @import("resources.zig");
const line_io = @import("../io/lines.zig");
const observation = @import("execution/observation.zig");
const http_io = @import("../io/http.zig");
const branching = @import("branch.zig");
const branch_runtime = @import("runtime/branch.zig");
const completion = @import("runtime/completion.zig");
pub const FlowTag = opaque {};

pub fn isFlowType(comptime T: type) bool {
    return (@typeInfo(T) == .@"struct" or @typeInfo(T) == .@"union") and
        @hasDecl(T, "flow_tag") and T.flow_tag == FlowTag;
}

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

        pub fn prepare(self: *@This(), scope: *Scope) !void {
            try self.consumer.prepare(scope.allocator);
            const node = try resolve(scope, &self.source);
            if (node.scoped_http and @hasDecl(Consumer, "http_scoped_supported")) {
                if (!Consumer.http_scoped_supported) return error.UnsupportedHttpComposition;
            }
            self.reader = try node.acquire(scope.allocator);
            if (@hasDecl(Consumer, "prepareResources"))
                try self.consumer.prepareResources(&scope.resources);
        }

        pub fn execute(self: *@This(), allocator: std.mem.Allocator, io: std.Io) !void {
            try self.consumer.consume(self.reader.?, allocator, io);
            // Success retires this branch. Failure is reported first and uses
            // run-wide shutdown, preserving signal backpressure during unwind.
            self.reader.?.close();
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.consumer.deinit(allocator);
        }

        pub fn completionOwner(self: *@This()) ?completion.Owner {
            return self.reader.?.completionOwner();
        }
    };
}

fn BranchPlan(comptime Item: type, comptime Cases: type) type {
    const fields = @typeInfo(Cases).@"struct".field_types;
    const terminal = branching.Terminates(Item, Cases);
    const Pipelines = blk: {
        var types: [fields.len]type = undefined;
        for (fields, 0..) |C, i| types[i] = branching.CaseOutput(Item, C);
        break :blk @Tuple(&types);
    };
    return struct {
        const Self = @This();
        node: Node,
        router: branch_runtime.Router(Item, Cases),
        pipelines: Pipelines = undefined,
        constructed: usize = 0,
        scoped_http: bool,

        fn finalize(_: *anyopaque) void {}
        fn stop(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.router.stop();
        }
        fn destroy(context: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (terminal) inline for (0..fields.len) |i| {
                if (i < self.constructed) self.pipelines[i].deinit(allocator);
            };
            allocator.destroy(self);
        }
    };
}

fn prepareBranch(scope: *Scope, source: anytype, cases: anytype) !*BranchPlan(
    sequences.Item(@typeInfo(@TypeOf(source)).pointer.child),
    @TypeOf(cases),
) {
    const Item = sequences.Item(@typeInfo(@TypeOf(source)).pointer.child);
    const Cases = @TypeOf(cases);
    const Plan = BranchPlan(Item, Cases);
    const terminal = comptime branching.Terminates(Item, Cases);
    const upstream = try resolve(scope, source);
    const input = try upstream.acquire(scope.allocator);
    try scope.reserve();
    const plan = try scope.allocator.create(Plan);
    plan.* = .{
        .node = .{
            .context = plan,
            .finalize = Plan.finalize,
            .stop = Plan.stop,
            .destroy = Plan.destroy,
            .stop_before_dependents = true,
        },
        .router = .{ .io = scope.io, .input = input, .cases = cases },
        .scoped_http = upstream.scoped_http,
    };
    scope.nodes.appendAssumeCapacity(&plan.node);
    inline for (0..cases.len) |i| {
        try scope.reserve();
        const outlet = blk: {
            const owner = try scope.allocator.create(streams.Stream(Item));
            errdefer scope.allocator.destroy(owner);
            owner.* = try plan.router.outlet(scope.allocator, i);
            errdefer owner.deinit();
            owner.setCompletion(upstream.owner.completionOwner());
            break :blk try Runtime(Item).create(scope.allocator, owner, 1, .{});
        };
        outlet.scoped_http = upstream.scoped_http;
        const Retire = struct {
            fn close(context: *anyopaque) void {
                const router: *@TypeOf(plan.router) = @ptrCast(@alignCast(context));
                router.retire(i);
            }
        };
        outlet.on_retire = .{ .context = &plan.router, .close = Retire.close };
        plan.router.outlets[i] = outlet.owner;
        plan.router.active[i] = true;
        scope.nodes.appendAssumeCapacity(&outlet.node);
        // Ownership transferred to the node. Later failures are unwound by Scope.
        const declaration: branching.Input(Item) = .{ .node = outlet };
        plan.pipelines[i] = if (@hasDecl(@TypeOf(cases[i]), "bound_case"))
            try cases[i].build(declaration)
        else
            @import("../pipe.zig").pipe(declaration, cases[i].operators);
        plan.constructed += 1;
        if (terminal) {
            try plan.pipelines[i].prepare(scope);
            if (!sameCompletion(input.completionOwner(), plan.pipelines[i].completionOwner()))
                return error.UnsupportedHttpComposition;
        }
    }
    return plan;
}

/// Internal terminal representation for all-terminating branch cases.
pub fn BranchFlow(comptime Input: type, comptime Cases: type) type {
    const Plan = BranchPlan(sequences.Item(Input), Cases);
    return struct {
        pub const flow_tag = FlowTag;
        source: Input,
        cases: Cases,
        plan: ?*Plan = null,
        execution: ?Execution = null,
        group: std.Io.Group = .init,

        pub fn prepare(self: *@This(), scope: *Scope) !void {
            self.plan = try prepareBranch(scope, &self.source, self.cases);
            const count = @typeInfo(Cases).@"struct".field_types.len;
            self.execution = .{ .allocator = scope.allocator, .io = scope.io, .remaining = count };
            // Case workers are prepared behind their own gate before service/
            // listener acquisition, just like the outer terminal workers.
            inline for (0..count) |i| {
                const Worker = struct {
                    fn work(control: *Execution, flow: *@TypeOf(self.plan.?.pipelines[i])) void {
                        const result = executeCase(control, flow);
                        control.finish(result);
                    }
                    fn executeCase(control: *Execution, flow: *@TypeOf(self.plan.?.pipelines[i])) !void {
                        try control.armed.wait(control.io);
                        try flow.execute(control.allocator, control.io);
                    }
                };
                try self.group.concurrent(scope.io, Worker.work, .{ &self.execution.?, &self.plan.?.pipelines[i] });
            }
        }
        pub fn execute(self: *@This(), _: std.mem.Allocator, io: std.Io) !void {
            const execution = &self.execution.?;
            defer self.group.cancel(io);
            defer self.plan.?.router.stop();
            errdefer if (self.plan.?.router.input.completionOwner()) |owner| owner.abort();
            try io.checkCancel();
            execution.armed.set(io);
            execution.done.wait(io) catch |err| return execution.failure() orelse err;
            if (execution.failure()) |err| return err;
            try self.group.await(io);
        }
        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            if (self.execution) |*execution| self.group.cancel(execution.io);
        }
        pub fn completionOwner(self: *@This()) ?completion.Owner {
            return self.plan.?.router.input.completionOwner();
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
/// Successful branches detach; unused stream nodes stop and retire their input
/// edges without stopping demanded siblings. State families stay run-scoped.
/// Preserve input order; independent nodes/effects can execute concurrently.
/// Descriptions must stay valid/unmodified, capability referents alive and safe
/// for concurrent use. Each new run creates fresh state and calls producers again.
///
/// Run owns queues/readers/workers, terminal buffers, and signal caches. It joins
/// consumers before freeing buffers, stops state updaters before transport,
/// and frees caches after samplers join. Dispatcher/I/O work is interrupted
/// before dependent joins; ordinary derived workers stop before producers.
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
/// See docs/execution.md and examples/streams.zig for the cross-operator lifecycle.
pub fn run(allocator: std.mem.Allocator, io: std.Io, flows: anytype) anyerror!void {
    return runObserved(allocator, io, flows, observation.Noop{});
}

// Private benchmark counterpart, with no public runtime observer registry.
pub fn runObserved(allocator: std.mem.Allocator, io: std.Io, flows: anytype, observer: anytype) anyerror!void {
    const Activation = struct {
        fn start(_: @This()) !void {}
    };
    return runPreparedObserved(allocator, io, flows, Activation{}, observer);
}

// The public executor supplies a typed resource activation hook. It runs only
// after graph preparation/gated startup, before I/O acquisition and callbacks.
pub fn runPrepared(allocator: std.mem.Allocator, io: std.Io, flows: anytype, activation: anytype) anyerror!void {
    return runPreparedObserved(allocator, io, flows, activation, observation.Noop{});
}

pub fn runPreparedObserved(allocator: std.mem.Allocator, io: std.Io, flows: anytype, activation: anytype, observer: anytype) anyerror!void {
    const Flows = @TypeOf(flows);
    if (comptime !composition.isTuple(Flows))
        @compileError("run: expected a nonempty flat tuple of terminal effect flows");
    const count = @typeInfo(Flows).@"struct".field_types.len;
    if (count == 0) @compileError("run: expected a nonempty flat tuple of terminal effect flows");
    inline for (@typeInfo(Flows).@"struct".field_types) |T| {
        if ((@typeInfo(T) != .@"struct" and @typeInfo(T) != .@"union") or !@hasDecl(T, "flow_tag") or T.flow_tag != FlowTag)
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
    defer scope.interrupt();
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
    observer.mark(.prepared);
    try activation.start();
    try scope.resources.acquireAll();
    for (scope.families.items) |family| try family.initialize();
    try io.checkCancel();
    observer.mark(.activation_ready);
    execution.armed.set(io);
    const result: anyerror!void = observed: {
        execution.done.wait(io) catch |err| break :observed execution.failure() orelse err;
        if (execution.failure()) |err| break :observed err;
    };
    observer.mark(.result_observed);
    try result;
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
const Edge = struct {
    context: *anyopaque,
    close: *const fn (*anyopaque) void,
};
const Node = struct {
    context: *anyopaque,
    finalize: *const fn (*anyopaque) void,
    stop: *const fn (*anyopaque) void,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    stop_before_dependents: bool = false,
};

const Scope = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    resources: resources.Scope,
    index: std.AutoHashMapUnmanaged(Key, *Node) = .{},
    nodes: std.ArrayList(*Node) = .empty,
    signal_index: std.AutoHashMapUnmanaged(Key, *state.Entry) = .{},
    families: std.ArrayList(*state.Family) = .empty,
    interrupted: bool = false,

    pub fn reserve(self: *@This()) !void {
        try self.index.ensureUnusedCapacity(self.allocator, 1);
        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
    }

    fn insert(self: *@This(), key: Key, node: *Node) void {
        self.index.putAssumeCapacity(key, node);
        self.nodes.appendAssumeCapacity(node);
    }

    fn interrupt(self: *@This()) void {
        if (self.interrupted) return;
        self.interrupted = true;
        // Interrupt connected I/O before joins. Handles/storage still survive
        // until all tasks have joined; shutdown is not resource destruction.
        self.resources.interruptAll();
        // An HTTP source can be blocked accepting without any input edge to
        // retire. Cancel its actual future before joining dependent forwarders;
        // canceling only a dependent may leave a nested accept uninterruptible.
        for (self.nodes.items) |node| {
            if (node.stop_before_dependents) node.stop(node.context);
        }
    }

    fn deinit(self: *@This()) void {
        self.interrupt();
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

pub fn Runtime(comptime T: type) type {
    return struct {
        const Self = @This();
        node: Node,
        owner: *streams.Stream(T),
        capacity: usize,
        split: streams.Stream(T).Split,
        inputs: []Edge,
        used: usize = 0,
        clones: std.ArrayList(*streams.Stream(T).Reader) = .empty,
        scoped_http: bool = false,
        on_retire: ?Edge = null,

        pub fn create(gpa: std.mem.Allocator, owner: *streams.Stream(T), capacity: usize, inputs: anytype) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const edges = try gpa.alloc(Edge, inputs.len);
            errdefer gpa.free(edges);
            inline for (inputs, 0..) |input, i| {
                const Reader = @typeInfo(@TypeOf(input)).pointer.child;
                const Close = struct {
                    fn call(context: *anyopaque) void {
                        const reader: *Reader = @ptrCast(@alignCast(context));
                        reader.close();
                    }
                };
                edges[i] = .{ .context = input, .close = Close.call };
            }
            const split = try streams.tee(owner);
            self.* = .{
                .node = .{ .context = self, .finalize = finalize, .stop = stop, .destroy = destroy },
                .owner = owner,
                .capacity = capacity,
                .split = split,
                .inputs = edges,
            };
            owner.setRetirement(self, retireInputs, unused);
            return self;
        }

        pub fn acquire(self: *Self, gpa: std.mem.Allocator) !*streams.Stream(T).Reader {
            // HTTP request scopes cannot be recycled while an independent
            // observer still holds a shallow snapshot of their storage.
            if (self.scoped_http and self.used != 0) return error.UnsupportedHttpFanout;
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
        fn retireInputs(context: *anyopaque) void {
            // Reader.close is synchronized and idempotent. Different producers
            // may retire sibling edges concurrently; never infer ownership from
            // arbitrary iterator fields or close run-scoped signal dependencies.
            for (cast(context).inputs) |edge| edge.close(edge.context);
        }
        fn unused(context: *anyopaque) void {
            retireInputs(context);
            if (cast(context).on_retire) |edge| edge.close(edge.context);
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
            gpa.free(self.inputs);
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
pub fn resolve(scope: *Scope, value: anytype) anyerror!*Runtime(sequences.Item(@typeInfo(@TypeOf(value)).pointer.child)) {
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

    if (comptime branching.isInput(Definition)) {
        return @ptrCast(@alignCast(reference.node));
    } else if (comptime branching.isBranch(Definition)) {
        const plan = try prepareBranch(scope, &reference.source, reference.cases);
        const count = @typeInfo(@TypeOf(reference.cases)).@"struct".field_types.len;
        var readers: [count]*streams.Stream(Element).Reader = undefined;
        inline for (0..count) |i| {
            const output = try resolve(scope, &plan.pipelines[i]);
            if (!sameCompletion(plan.router.input.completionOwner(), output.owner.completionOwner()))
                return error.UnsupportedHttpComposition;
            readers[i] = try output.acquire(scope.allocator);
        }
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = try streams.merge(scope.allocator, scope.io, 1, readers);
        errdefer owner.deinit();
        owner.setCompletion(plan.router.input.completionOwner());
        const runtime = try Runtime(Element).create(scope.allocator, owner, 1, readers);
        runtime.scoped_http = plan.scoped_http;
        scope.insert(key, &runtime.node);
        return runtime;
    } else if (comptime line_io.isSource(Definition) or http_io.isSource(Definition)) {
        if (reference.capacity == 0) return error.UnsupportedCapacity;
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = try reference.instantiate(&scope.resources);
        errdefer owner.deinit();
        const runtime = try Runtime(Element).create(scope.allocator, owner, reference.capacity, .{});
        runtime.scoped_http = comptime http_io.isSource(Definition);
        runtime.node.stop_before_dependents = runtime.scoped_http;
        scope.insert(key, &runtime.node);
        return runtime;
    } else if (root) {
        if (reference.capacity == 0) return error.UnsupportedCapacity;
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = try sources.instantiate(reference.*, scope.allocator, scope.io);
        errdefer owner.deinit();
        const runtime = try Runtime(Element).create(scope.allocator, owner, reference.capacity, .{});
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
        const runtime = try Runtime(Element).create(scope.allocator, owner, 1, .{});
        scope.insert(key, &runtime.node);
        cell.observation = owner;
        cell.observation_node = runtime;
        return runtime;
    } else if (comptime signal_kind.isSample(Definition)) {
        const cell = try resolveSignal(scope, &reference.signal);
        const upstream = try resolve(scope, &reference.source);
        if (upstream.scoped_http) return error.UnsupportedHttpComposition;
        const reader = try upstream.acquire(scope.allocator);
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = try state.sample(scope.allocator, scope.io, reader, signal_kind.Value(@TypeOf(reference.signal)), cell);
        errdefer owner.deinit();
        const runtime = try Runtime(Element).create(scope.allocator, owner, 1, .{reader});
        scope.insert(key, &runtime.node);
        return runtime;
    } else if (comptime merging.isMerge(Definition)) {
        const count = @typeInfo(@TypeOf(reference.inputs)).@"struct".field_types.len;
        var readers: [count]*streams.Stream(Element).Reader = undefined;
        inline for (0..count) |i| {
            const upstream = try resolve(scope, &reference.inputs[i]);
            if (upstream.scoped_http) return error.UnsupportedHttpComposition;
            readers[i] = try upstream.acquire(scope.allocator);
        }
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = try streams.merge(scope.allocator, scope.io, 1, readers);
        errdefer owner.deinit();
        const runtime = try Runtime(Element).create(scope.allocator, owner, 1, readers);
        scope.insert(key, &runtime.node);
        return runtime;
    } else if (comptime @typeInfo(Definition) == .@"struct" and @hasDecl(Definition, "region_source")) {
        const runtime = try reference.materialize(scope);
        scope.insert(key, &runtime.node);
        return runtime;
    } else if (comptime @typeInfo(Definition) == .@"struct" and @hasDecl(Definition, "declaration_source")) {
        const upstream = try resolve(scope, &reference.source);
        if (upstream.scoped_http and Definition.declaration_kind != .mapped and
            Definition.declaration_kind != .filtered and Definition.declaration_kind != .taken)
            return error.UnsupportedHttpComposition;
        const reader = try upstream.acquire(scope.allocator);
        try scope.reserve();
        const owner = try scope.allocator.create(streams.Stream(Element));
        errdefer scope.allocator.destroy(owner);
        owner.* = if (Definition.declaration_kind == .retained)
            try streams.takeLast(scope.allocator, scope.io, upstream.capacity, reader, reference.limit)
        else if (Definition.declaration_kind == .scanned)
            try streams.scan(scope.allocator, scope.io, upstream.capacity, reader, reference.initial, Definition.declaration_reducer)
        else block: {
            const view = if (@hasDecl(Definition, "bound_region"))
                reference.view(reader)
            else if (Definition.declaration_kind == .mapped)
                each(Definition.declaration_functions).apply(reader)
            else if (Definition.declaration_kind == .filtered)
                filter(Definition.declaration_predicate).apply(reader)
            else if (Definition.declaration_kind == .bounded)
                maxItems(reference.limit).apply(reader)
            else if (Definition.declaration_kind == .taken)
                take(reference.limit).apply(reader)
            else
                @compileError("run: unsupported declaration kind");
            break :block try streams.share(scope.allocator, scope.io, upstream.capacity, view);
        };
        errdefer owner.deinit();
        owner.setCompletion(upstream.owner.completionOwner());
        const runtime = try Runtime(Element).create(scope.allocator, owner, upstream.capacity, .{reader});
        runtime.scoped_http = upstream.scoped_http;
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
        const runtime = try Runtime(Element).create(scope.allocator, owner, 1, .{});
        scope.insert(key, &runtime.node);
        return runtime;
    }
}

fn sameCompletion(a: ?completion.Owner, b: ?completion.Owner) bool {
    if (a) |left| return if (b) |right| left.context == right.context else false;
    return b == null;
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
        if (upstream.scoped_http) return error.UnsupportedHttpComposition;
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
                if (@hasDecl(Definition, "bound_signal"))
                    target.candidate = Definition.compute(target.binding.?, input.candidate)
                else
                    target.candidate = composition.compose(input.candidate, Definition.signal_functions, 0);
            }
        };
        cell.entry.parent = &parent.entry;
        if (@hasDecl(Definition, "bound_signal")) cell.binding = reference.env;
        cell.entry.compute = Compute.candidate;
        parent.family.entries.appendAssumeCapacity(&cell.entry);
        scope.signal_index.putAssumeCapacity(key, &cell.entry);
        return cell;
    }
}
