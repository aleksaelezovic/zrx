//! Bindings: what a program is given to build its environment from.
//!
//! A binding is a plain value, which provides its own type, or a *resource*:
//!
//!     pub const zrx_resource = {};
//!     pub const Provides: type
//!     pub const needs: []const type
//!     pub fn bind(self, env: anytype, next: anytype) !void
//!
//! `env` holds at least `needs`; `bind` calls `next.call(value)` once with
//! the `Provides` it acquired, and whatever it does after that call returns
//! is its release. The order of acquisition is worked out at compile time
//! from what each binding provides and needs; nothing of it exists at runtime.
const di = @import("di.zig");
const lift = @import("pipe.zig").lift;

pub fn resource(comptime acquire: anytype, comptime release: anytype) Resource(acquire, release) {
    return .{};
}

fn Resource(comptime acquire: anytype, comptime release: anytype) type {
    @setEvalBranchQuota(di.quota);
    const Value = di.Payload(di.Result("resource acquire", acquire, &.{}));
    if (Value == void) @compileError("resource: acquire must return the value to provide");
    const releases = @TypeOf(release) != @TypeOf(null);
    if (releases and di.Result("resource release", release, &.{Value}) != void)
        @compileError("resource: release must return `void`; a release cannot fail");
    return struct {
        pub const zrx_resource = {};
        pub const Provides = Value;
        pub const needs = di.merge(
            di.requires("resource acquire", acquire, 0),
            if (releases) di.requires("resource release", release, 1) else &.{},
        );

        pub fn bind(_: @This(), env: anytype, next: anytype) !void {
            const Env = @TypeOf(env);
            const Acquire = di.Bound("resource acquire", acquire, Env, &.{});
            const Release = if (releases) di.Bound("resource release", release, Env, &.{Value}) else void;

            const open: Acquire = .init(env);
            const close: Release = if (releases) .init(env) else {};
            const value = try lift(open.call(.{}));
            defer if (releases) close.call(.{value});
            return next.call(value);
        }
    };
}

fn isResource(comptime B: type) bool {
    return @typeInfo(B) == .@"struct" and @hasDecl(B, "zrx_resource");
}

/// The type a binding puts into the environment.
fn Provided(comptime B: type) type {
    return if (isResource(B)) B.Provides else B;
}

fn contains(comptime list: []const type, comptime T: type) bool {
    for (list) |Have| if (Have == T) return true;
    return false;
}

/// A tuple of bindings in which every type has one provider.
pub fn Bindings(comptime Given: type) type {
    @setEvalBranchQuota(di.quota);
    const list = di.types(di.Normalized(Given));
    for (list, 0..) |B, i| for (list[0..i]) |Earlier| if (Provided(Earlier) == Provided(B)) @compileError(
        "zrx: dependency type `" ++ @typeName(Provided(B)) ++ "` is provided twice, by " ++ describe(Earlier) ++ " and by " ++ describe(B) ++
            "; keep one of them, or have one provide a distinct struct type",
    );
    return @Tuple(list);
}

fn describe(comptime B: type) []const u8 {
    return if (isResource(B)) "`" ++ @typeName(B) ++ "`" else "a value";
}

/// Positions in `defaults ++ given`: the values, then the resources in the
/// order they are acquired.
const Plan = struct {
    values: []const usize,
    resources: []const usize,
};

/// Plain values come first. Then, again and again, the first resource in
/// written order whose needs are all there. A default whose type is also
/// given is left out: it is neither provided nor acquired.
fn plan(comptime Defaults: type, comptime Given: type) Plan {
    @setEvalBranchQuota(di.quota);
    const given = di.types(Bindings(Given));
    const all = di.types(Defaults) ++ given;
    const overridable = di.types(Defaults).len;

    var values: []const usize = &.{};
    var pending: []const usize = &.{};
    var available: []const type = &.{};
    next: for (all, 0..) |B, i| {
        if (i < overridable) for (given) |Over| if (Provided(Over) == Provided(B)) continue :next;
        if (isResource(B)) {
            pending = pending ++ [_]usize{i};
        } else {
            values = values ++ [_]usize{i};
            available = available ++ [_]type{B};
        }
    }

    var resources: []const usize = &.{};
    placing: while (pending.len != 0) {
        for (pending, 0..) |i, at| {
            const ready = for (all[i].needs) |Need| {
                if (!contains(available, Need)) break false;
            } else true;
            if (!ready) continue;
            resources = resources ++ [_]usize{i};
            available = available ++ [_]type{all[i].Provides};
            pending = pending[0..at] ++ pending[at + 1 ..];
            continue :placing;
        }
        @compileError(stuck(all, pending, available));
    }
    return .{ .values = values, .resources = resources };
}

/// Why none of `pending` can be acquired: a need nobody provides, or
/// bindings that wait for one another.
fn stuck(comptime all: []const type, comptime pending: []const usize, comptime available: []const type) []const u8 {
    var provided = available;
    for (pending) |i| provided = provided ++ [_]type{all[i].Provides};
    for (pending) |i| for (all[i].needs) |Need| {
        if (contains(provided, Need)) continue;
        var others: []const type = &.{};
        for (provided) |T| if (T != all[i].Provides) {
            others = others ++ [_]type{T};
        };
        return "zrx: `" ++ @typeName(all[i]) ++ "` needs dependency `" ++ @typeName(Need) ++
            "`, which is not provided; provided: " ++ di.listTypes(others) ++
            ". Pass it to `run(.{ ... })` or bind it with `program(...).provide(.{ ... })`.";
    };

    // Each one waits for another: follow them until one comes round again.
    var chain: []const usize = &.{pending[0]};
    const cycle = following: while (true) {
        const waits_for = provider: for (all[chain[chain.len - 1]].needs) |Need| {
            if (contains(available, Need)) continue;
            for (pending) |i| if (all[i].Provides == Need) break :provider i;
        } else unreachable;
        for (chain, 0..) |seen, start| if (seen == waits_for) break :following chain[start..];
        chain = chain ++ [_]usize{waits_for};
    };
    var text: []const u8 = "zrx: these bindings need each other, so none of them can be acquired first: ";
    for (cycle, 0..) |i, at| {
        const Need = all[cycle[(at + 1) % cycle.len]].Provides;
        text = text ++ (if (at == 0) "" else ", ") ++ "`" ++ @typeName(all[i]) ++ "` needs `" ++ @typeName(Need) ++ "`";
    }
    return text ++ ". Pass one of these as a value, or build it from something else.";
}

/// Calls `program.call(env)` with the environment built from `given` and
/// from the `defaults` it does not replace. Resources are held around the
/// call and released in the reverse of the order they were acquired in.
pub fn run(defaults: anytype, given: anytype, program: anytype) !void {
    const Defaults = @TypeOf(defaults);
    const Given = @TypeOf(given);
    const order = comptime plan(Defaults, Given);
    const types = comptime di.types(Defaults) ++ di.types(Given);
    const all: @Tuple(types) = defaults ++ given;

    const Values = comptime values: {
        var list: [order.values.len]type = undefined;
        for (order.values, 0..) |i, at| list[at] = types[i];
        break :values @Tuple(&list);
    };
    var env: Values = undefined;
    inline for (order.values, 0..) |i, at| env[at] = all[i];
    return hold(order.resources, all, env, program);
}

fn hold(comptime rest: []const usize, all: anytype, env: anytype, program: anytype) !void {
    if (rest.len == 0) return program.call(env);
    const binding = all[rest[0]];
    const Next = struct {
        all: @TypeOf(all),
        env: @TypeOf(env),
        program: @TypeOf(program),

        pub fn call(self: @This(), value: @TypeOf(binding).Provides) !void {
            return hold(rest[1..], self.all, di.extend(self.env, value), self.program);
        }
    };
    return binding.bind(env, Next{ .all = all, .env = env, .program = program });
}
