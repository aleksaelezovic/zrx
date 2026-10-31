//! Comptime service plan and typed run-local storage.
const std = @import("std");
const composition = @import("../composition.zig");
const resources = @import("resources.zig");
pub const FlowTag = opaque {};

/// Static type keys and DFS order; no runtime registry, lookup, or plan allocation.
/// The values tuple stays at its run-local address until all releases finish.
pub fn World(comptime Bindings: type, comptime Flows: type) type {
    if (!composition.isTuple(Bindings))
        @compileError("world: bindings must be a flat tuple");
    if (!composition.isTuple(Flows) or @typeInfo(Flows).@"struct".field_types.len == 0)
        @compileError("world: expected a nonempty flat tuple of terminal flows");
    const binding_types = @typeInfo(Bindings).@"struct".field_types;
    const flow_types = @typeInfo(Flows).@"struct".field_types;
    const count = binding_types.len;
    const service_types = block: {
        var types: [count]type = undefined;
        for (binding_types, 0..) |T, i| {
            if (composition.isTuple(T)) @compileError("world: bindings must be a flat tuple");
            types[i] = resources.Service(T);
            for (types[0..i]) |Earlier| {
                if (Earlier == types[i])
                    @compileError("world: duplicate binding for " ++ @typeName(types[i]));
            }
        }
        break :block types;
    };
    for (flow_types) |Flow| {
        if (@typeInfo(Flow) != .@"struct" or !@hasDecl(Flow, "world_flow_tag") or Flow.world_flow_tag != FlowTag)
            @compileError("world: selected roots must be terminal flows");
    }
    return struct {
        const Self = @This();
        pub const RootTypes = flow_types;
        const Order = struct { indices: [count]usize = undefined, len: usize = 0 };
        const order = plan();
        const SelectedBindings = block: {
            var types: [order.len]type = undefined;
            for (order.indices[0..order.len], 0..) |i, position| types[position] = binding_types[i];
            break :block @Tuple(&types);
        };
        const SelectedValues = block: {
            var types: [order.len]type = undefined;
            for (order.indices[0..order.len], 0..) |i, position| types[position] = service_types[i];
            break :block @Tuple(&types);
        };
        bindings: SelectedBindings,
        values: SelectedValues = undefined,
        acquired: usize = 0,

        pub fn init(bindings: Bindings) Self {
            var self: Self = .{ .bindings = undefined };
            inline for (order.indices[0..order.len], 0..) |i, position| self.bindings[position] = bindings[i];
            return self;
        }

        fn indexOf(comptime T: type) usize {
            for (service_types, 0..) |Service, i| if (Service == T) return i;
            @compileError("world: missing dependency " ++ @typeName(T));
        }

        fn positionOf(comptime Service: type) usize {
            const binding = indexOf(Service);
            for (order.indices[0..order.len], 0..) |i, position| if (i == binding) return position;
            @compileError("world: service was not declared reachable " ++ @typeName(Service));
        }

        fn visitServices(comptime Services: []const type, marks: *[count]u2, result: *Order) void {
            for (Services) |T| visit(indexOf(T), marks, result);
        }

        fn visit(index: usize, marks: *[count]u2, result: *Order) void {
            if (marks[index] == 2) return;
            if (marks[index] == 1)
                @compileError("world: dependency cycle at " ++ @typeName(service_types[index]));
            marks[index] = 1;
            const Binding = binding_types[index];
            if (resources.isRecipe(Binding)) {
                visitServices(&Binding.AcquireServices, marks, result);
                // Release dependencies must also outlive the dependent service.
                visitServices(&Binding.ReleaseServices, marks, result);
            }
            marks[index] = 2;
            result.indices[result.len] = index;
            result.len += 1;
        }

        fn plan() Order {
            var result: Order = .{};
            var marks: [count]u2 = @splat(0);
            for (.{ std.mem.Allocator, std.Io }) |T| {
                const i = indexOf(T);
                if (resources.isRecipe(binding_types[i]))
                    @compileError("world: allocator and Io bootstrap bindings must be supplied values");
                visit(i, &marks, &result);
            }
            for (flow_types) |Flow| {
                visitServices(&Flow.Requirements, &marks, &result);
            }
            return result;
        }

        pub fn io(self: *const Self) std.Io {
            // Bootstrap is directly supplied, even before values are initialized.
            return self.bindings[comptime positionOf(std.Io)];
        }

        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.bindings[comptime positionOf(std.mem.Allocator)];
        }

        pub fn get(self: *const Self, comptime Service: type) Service {
            return self.values[comptime positionOf(Service)];
        }

        pub fn start(self: *Self) !void {
            try self.io().checkCancel();
            inline for (order.indices[0..order.len], 0..) |i, position| {
                if (comptime resources.isRecipe(binding_types[i])) {
                    try self.io().checkCancel();
                    self.values[position] = try self.bindings[position].acquire(self);
                } else {
                    self.values[position] = self.bindings[position];
                }
                self.acquired += 1;
            }
        }

        pub fn stop(self: *Self) void {
            inline for (0..order.len) |reverse| {
                const step = order.len - 1 - reverse;
                const i = order.indices[step];
                if (self.acquired > step) {
                    if (comptime resources.isRecipe(binding_types[i]))
                        self.bindings[step].release(self, self.values[step]);
                }
            }
            self.acquired = 0;
        }
    };
}
