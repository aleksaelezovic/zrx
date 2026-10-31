//! The only public execution boundary: plan services, prepare, acquire, execute,
//! cancel/join when needed, and release. Graph construction never executes stages.
const std = @import("std");
const dependencies = @import("internal/world/dependencies.zig");
const cursors = @import("internal/execution/cursors.zig");
const regions = @import("internal/execution/regions.zig");
const binding = @import("internal/execution/bind.zig");
const graph = @import("internal/graph_run.zig");
const observation = @import("internal/execution/observation.zig");

/// Inject exact-type values or resource recipes. Allocator and Io must be supplied
/// directly. Only selected terminal roots execute. Errors fail the run without
/// rollback; callbacks must cooperate with cancellation and join escaped work.
pub fn run(bindings: anytype, flows: anytype) anyerror!void {
    return runObserved(bindings, flows, observation.Noop{});
}

// Accessible only through the private measurement facade, not the package root.
pub fn runObserved(bindings: anytype, flows: anytype, observer: anytype) anyerror!void {
    const Env = dependencies.World(@TypeOf(bindings), @TypeOf(flows));
    var env: Env = .init(bindings);
    defer env.stop();
    const types = @typeInfo(@TypeOf(flows)).@"struct".field_types;
    const direct = comptime block: {
        for (types) |F| {
            if (!cursors.finite(@FieldType(F, "source")) or @hasDecl(@FieldType(F, "consumer"), "prepareResources"))
                break :block false;
        }
        break :block true;
    };
    var scope: binding.Scope(Env) = .{ .allocator = env.allocator(), .env = &env };
    defer scope.deinit();
    inline for (flows) |flow| try scope.inspect(flow.source);
    if (direct and !scope.hasShared()) {
        var definitions: @Tuple(types) = undefined;
        inline for (0..flows.len) |i| definitions[i] = flows[i];
        defer inline for (0..flows.len) |i| definitions[i].consumer.deinit(env.allocator());
        inline for (0..flows.len) |i| try definitions[i].consumer.prepare(env.allocator());
        observer.mark(.prepared);
        try env.start();
        observer.mark(.activation_ready);
        const result: anyerror!void = execute: {
            inline for (0..flows.len) |i| {
                env.io().checkCancel() catch |err| break :execute err;
                const Source = @TypeOf(definitions[i].source);
                const view: regions.View(Source, Env) = .{ .input = definitions[i].source, .env = &env };
                definitions[i].consumer.consume(view, &env, env.allocator(), env.io()) catch |err| break :execute err;
            }
        };
        observer.mark(.result_observed);
        try result;
    } else {
        const bound_types = comptime block: {
            var result: [types.len]type = undefined;
            for (types, 0..) |F, i| result[i] = binding.Flow(F, Env);
            break :block result;
        };
        var bound: @Tuple(&bound_types) = undefined;
        inline for (0..flows.len) |i| bound[i] = try binding.flow(&scope, flows[i]);
        try graph.runPreparedObserved(env.allocator(), env.io(), bound, &env, observer);
    }
}
