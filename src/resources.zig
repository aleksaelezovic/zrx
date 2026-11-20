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
//!
//! A `rescue` is a binding too. What it holds around the call is not a
//! value but the call's failure.
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

/// Where the failure of a run goes: `run` returns nothing.
/// `handler(deps..., err)` is called once with it and returns nothing
/// either. It is a binding: it needs what its handler asks
/// for, and guards everything acquired after that is there, which is every
/// other resource and the run itself. Their failures reach the handler
/// after they have been released, while what it needs is still held.
///
/// The handler's error parameter selects what it takes: an error set,
/// `anyerror`, or `anytype` for exactly the errors the run can fail with.
/// A cancellation is one of them: an error path never takes one, but this
/// is where the run ends, and `run` has no other way to say so. A handler
/// whose caller must stay cancellable calls `io.recancel()` for it.
///
/// What the handler does not take is left over, and so is a failure of
/// acquiring what the handler itself needs. A run with anything left over
/// does not compile: `run` returns nothing.
pub fn rescue(comptime handler: anytype) Rescue(handler) {
    return .{};
}

/// What a `rescue` provides: nothing to use, but one type, so that a run
/// has one rescue and the one given to `run` replaces a program's default.
pub const Rescued = struct {};

fn Rescue(comptime handler: anytype) type {
    @setEvalBranchQuota(di.quota);
    if (!di.isHandler(handler)) @compileError("rescue: expected a handler `fn (deps..., err) void`, got `" ++ @typeName(@TypeOf(handler)) ++ "`");
    const Declared: ?type = di.Param(handler, 1, 0);
    if (Declared) |E| if (@typeInfo(E) != .error_set) @compileError(
        "rescue: the handler's data parameter is the failure of the run, so it must be an error set, `anyerror` or `anytype`, got `" ++ @typeName(E) ++ "`",
    );
    return struct {
        pub const zrx_resource = {};
        pub const zrx_rescue = {};
        pub const Provides = Rescued;
        pub const needs = di.requires("rescue", handler, 1);

        pub fn bind(_: @This(), env: anytype, next: anytype) !void {
            return next.call(Rescued{}) catch |err| {
                const any: anyerror = err;
                const Taken = comptime Declared orelse Named(@TypeOf(err));
                const Call = di.Bound("rescue", handler, @TypeOf(env), &.{Taken});
                if (comptime Call.Return != void) @compileError(
                    "rescue: the handler must return `void`, got `" ++ @typeName(Call.Return) ++ "`; it is the last to be given the failure, and `run` returns nothing. " ++
                        "What a run leaves behind is an effect, such as a status written through a dependency",
                );
                const call: Call = .init(env);
                if (comptime @typeInfo(@TypeOf(err)).error_set.error_names) |possible| {
                    // Every error the run can fail with is known: one the
                    // handler does not take is returned by its name, so that
                    // only those are left in the error set of the run.
                    // The last of them needs no asking: it is the one left.
                    inline for (possible, 1..) |error_name, nth| {
                        if (nth == possible.len or any == @field(anyerror, error_name)) {
                            if (comptime !holds(Taken, error_name)) return @field(anyerror, error_name);
                            return call.call(.{@as(Taken, @errorCast(any))});
                        }
                    }
                    comptime unreachable;
                }
                if (comptime @typeInfo(Taken).error_set.error_names) |names| {
                    inline for (names) |error_name| {
                        if (any == @field(anyerror, error_name)) return call.call(.{@as(Taken, @errorCast(any))});
                    }
                    return err;
                }
                return call.call(.{any});
            };
        }
    };
}

/// `E` as one would write it: an inferred error set is a type of its own,
/// which a handler could not name.
fn Named(comptime E: type) type {
    const names = @typeInfo(E).error_set.error_names orelse return anyerror;
    var Set = error{};
    for (names) |error_name| Set = Set || @TypeOf(@field(anyerror, error_name));
    return Set;
}

/// Whether the error set `E`, or `anyerror`, holds the error of this name.
/// A cancellation is one of them here: an error path leaves it alone
/// because it is no item's, but a rescue is where the run ends.
fn holds(comptime E: type, comptime error_name: []const u8) bool {
    const names = @typeInfo(E).error_set.error_names orelse return true; // anyerror
    for (names) |have| if (eql(have, error_name)) return true;
    return false;
}

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn isRescue(comptime B: type) bool {
    return isResource(B) and @hasDecl(B, "zrx_rescue");
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
        if (isRescue(Earlier) and isRescue(B))
            "zrx: two `rescue` bindings are given together, but the failure of a run goes to one place; keep one. Given to `run`, a rescue replaces the one a program provides"
        else
            "zrx: dependency type `" ++ @typeName(Provided(B)) ++ "` is provided twice, by " ++ describe(Earlier) ++ " and by " ++ describe(B) ++
                "; keep one of them, or have one provide a distinct struct type",
    );
    return @Tuple(list);
}

fn describe(comptime B: type) []const u8 {
    return if (isResource(B)) "`" ++ @typeName(B) ++ "`" else "a value";
}

/// An environment handed on as it is: every element is a value, whatever
/// its type looks like. A system gives its programs what it resolved this
/// way; sorting those values into values and resources a second time would
/// take a value that has the shape of a binding for a binding.
pub fn Resolved(comptime Env: type) type {
    return struct {
        env: Env,

        pub const zrx_resolved = {};
    };
}

pub fn resolved(env: anytype) Resolved(@TypeOf(env)) {
    return .{ .env = env };
}

fn isResolved(comptime Given: type) bool {
    return @typeInfo(Given) == .@"struct" and @hasDecl(Given, "zrx_resolved");
}

/// Positions in `defaults ++ given`: the values, then the resources in the
/// order they are acquired.
const Plan = struct {
    values: []const usize,
    resources: []const usize,
};

/// Plain values come first. Then, again and again, the first resource in
/// written order whose needs are all there; a rescue before any other, so
/// that wherever it is written it guards all it can. A default whose type
/// is also given is left out: it is neither provided nor acquired.
fn plan(comptime Defaults: type, comptime Given: type, comptime given_values: bool) Plan {
    @setEvalBranchQuota(di.quota);
    const given = if (given_values) di.types(Given) else di.types(Bindings(Given));
    const all = di.types(Defaults) ++ given;
    const overridable = di.types(Defaults).len;

    var values: []const usize = &.{};
    var pending: []const usize = &.{};
    var available: []const type = &.{};
    next: for (all, 0..) |B, i| {
        if (i < overridable) for (given) |Over| {
            if ((if (given_values) Over else Provided(Over)) == Provided(B)) continue :next;
        };
        if (isResource(B) and (i < overridable or !given_values)) {
            pending = pending ++ [_]usize{i};
        } else {
            values = values ++ [_]usize{i};
            available = available ++ [_]type{B};
        }
    }

    var resources: []const usize = &.{};
    placing: while (pending.len != 0) {
        for ([_]bool{ true, false }) |rescues| for (pending, 0..) |i, at| {
            if (isRescue(all[i]) != rescues) continue;
            const ready = for (all[i].needs) |Need| {
                if (!contains(available, Need)) break false;
            } else true;
            if (!ready) continue;
            resources = resources ++ [_]usize{i};
            available = available ++ [_]type{all[i].Provides};
            pending = pending[0..at] ++ pending[at + 1 ..];
            continue :placing;
        };
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
    if (comptime isResolved(@TypeOf(given))) return runWith(defaults, given.env, true, program);
    return runWith(defaults, given, false, program);
}

fn runWith(defaults: anytype, given: anytype, comptime given_values: bool, program: anytype) !void {
    const Defaults = @TypeOf(defaults);
    const Given = @TypeOf(given);
    const order = comptime plan(Defaults, Given, given_values);
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
