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
//! A `rescue` is the third kind of binding. It provides nothing and is not
//! acquired: it stands outside the run, and is given what the run failed
//! with once everything the run acquired has been released.
const di = @import("di.zig");
const failure = @import("failure.zig");
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
/// either: it is the last to be given the failure.
///
/// A rescue stands outside the run. It is called when the run is over and
/// every resource the run acquired has been released, whichever of them
/// failed and wherever the rescue is written among the bindings. Its
/// handler is given the plain values of the run, and what the rescue is
/// given for itself: `rescue(fatal).provide(.{ stderr(256) })`. Those are
/// acquired for the call and released after it. A resource of the run is
/// gone by then, and asking for one is a compile error.
///
/// The handler's error parameter says what it takes: `anyerror`, an error
/// set, or `anytype` for exactly the errors the run can fail with. A
/// cancellation is one of them: an error path never takes one, but this is
/// where the run ends. What the handler does not take is left over, and so
/// is a failure of acquiring what the rescue itself was given. A run with
/// anything left over does not compile.
pub fn rescue(comptime handler: anytype) Rescue(handler, @Tuple(&.{})) {
    return .{ .bindings = .{} };
}

fn Rescue(comptime handler: anytype, comptime Own: type) type {
    @setEvalBranchQuota(di.quota);
    if (!di.isHandler(handler)) @compileError("rescue: expected a handler `fn (deps..., err) void`, got `" ++ @typeName(@TypeOf(handler)) ++ "`");
    const Declared: ?type = di.Param("rescue", handler, 1, 0);
    if (Declared) |E| if (@typeInfo(E) != .error_set) @compileError(
        "rescue: the handler's data parameter is the failure of the run, so it must be an error set, `anyerror` or `anytype`, got `" ++ @typeName(E) ++ "`",
    );
    // Checked here, where the rescue is written, and not where it is
    // called: a run that cannot fail never calls it.
    if (declaredReturn(handler)) |Returned| expectNothing(Returned);
    return struct {
        bindings: Own,

        pub const zrx_rescue: Mark = .{};

        const Self = @This();

        /// Gives the rescue bindings of its own, for what its handler needs
        /// beyond the plain values of the run.
        pub fn provide(self: Self, bindings: anytype) Rescue(handler, OwnBindings(Own, @TypeOf(bindings))) {
            return .{ .bindings = self.bindings ++ bindings };
        }

        /// What the handler is given, of the errors in `Possible`.
        fn Taken(comptime Possible: type) type {
            return Declared orelse failure.Named(Possible);
        }

        /// Everything that can be wrong with this rescue for a run with
        /// these values that can fail with `Possible`. `held` is what the
        /// run's own resources provide. Evaluated for every run, also one
        /// that cannot fail.
        fn check(comptime Values: type, comptime Possible: type, comptime held: []const type) void {
            @setEvalBranchQuota(di.quota);
            // A return type that is not declared exists only for the errors
            // the handler is called with. With none, there is no call to
            // ask about, and asking would have the handler's body checked
            // against errors that cannot occur.
            if (declaredReturn(handler) == null and callable(Taken(Possible)))
                expectNothing(di.Result("rescue", handler, &.{Taken(Possible)}));
            // Its own bindings must be acquirable from the values alone.
            const own = plan(Own, Values, true, true);
            var provided: []const type = di.types(Values);
            for (own.resources) |i| provided = provided ++ [_]type{di.types(Own)[i].Provides};
            for (own.values) |i| {
                if (i < di.types(Own).len) provided = provided ++ [_]type{di.types(Own)[i]};
            }
            for (di.requires("rescue", handler, 1)) |Need| {
                if (contains(provided, Need)) continue;
                if (contains(held, Need)) @compileError(
                    "rescue: the handler asks for `" ++ @typeName(Need) ++ "`, which a resource of the run provides. A rescue is called when the run is over " ++
                        "and what it acquired has been released; give the rescue one of its own: `rescue(handler).provide(.{ ... })`",
                );
                @compileError(
                    "rescue: the handler asks for dependency `" ++ @typeName(Need) ++ "`, which is not provided; provided: " ++ di.listTypes(provided) ++
                        ". Pass it to `run(.{ ... })` as a value, or give it to the rescue with `rescue(handler).provide(.{ ... })`.",
                );
            }
        }

        /// The run failed with `err`, and everything it acquired has been
        /// released. `values` are the plain values it was run with.
        fn handle(self: Self, values: anytype, err: anytype) !void {
            const T = Taken(@TypeOf(err));
            switch (failure.take(T, .taken, err)) {
                .left => |rest| return rest,
                .taken => |taken| return run(self.bindings, resolved(values, true), Handle(T){ .err = taken }),
            }
        }

        fn Handle(comptime T: type) type {
            return struct {
                err: T,

                pub fn call(body: @This(), env: anytype, comptime _: bool) !void {
                    const bound: di.Bound("rescue", handler, @TypeOf(env), &.{T}) = .init(env);
                    bound.call(.{body.err});
                }
            };
        }
    };
}

/// What `handler` says it returns, where that does not depend on what it
/// is called with. Read from its type: nothing of its body is looked at.
fn declaredReturn(comptime handler: anytype) ?type {
    if (@typeInfo(@TypeOf(handler)) != .@"fn") return null; // a composite handler
    return @typeInfo(@TypeOf(handler)).@"fn".return_type;
}

/// Whether a handler that takes `Taken` can be called at all.
fn callable(comptime Taken: type) bool {
    const names = @typeInfo(Taken).error_set.error_names orelse return true; // anyerror
    return names.len != 0;
}

fn expectNothing(comptime Returned: type) void {
    if (Returned != void) @compileError(
        "rescue: the handler must return `void`, got `" ++ @typeName(Returned) ++ "`; it is the last to be given the failure, and `run` returns nothing. " ++
            "What a run leaves behind is an effect, such as a status written through a dependency",
    );
}

/// The bindings a rescue is given for itself.
fn OwnBindings(comptime A: type, comptime B: type) type {
    if (!di.isTuple(B)) @compileError("rescue.provide: expected a tuple of bindings such as `.{ stderr(256) }`");
    for (di.types(B)) |Binding| if (isRescue(Binding)) @compileError(
        "rescue.provide: a rescue has no rescue of its own; what fails while it is called is left over, which `run` refuses",
    );
    return Bindings(@Tuple(di.types(A) ++ di.types(B)));
}

/// Marks what only this file makes: a rescue, and an environment handed on
/// as resolved. The type is private, so nothing a caller declares carries
/// it, whatever the caller names its declarations. A resource is told by
/// `zrx_resource` alone because that is the contract a caller writes one
/// against; these two have no such contract.
const Mark = struct {};

fn isMarked(comptime B: type, comptime mark: []const u8) bool {
    return @typeInfo(B) == .@"struct" and @hasDecl(B, mark) and @TypeOf(@field(B, mark)) == Mark;
}

fn isRescue(comptime B: type) bool {
    return isMarked(B, "zrx_rescue");
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
    for (list, 0..) |B, i| for (list[0..i]) |Earlier| {
        if (isRescue(Earlier) and isRescue(B)) @compileError(
            "zrx: two `rescue` bindings are given together, but the failure of a run goes to one place; keep one. Given to `run`, a rescue replaces the one a program provides",
        );
        if (isRescue(Earlier) or isRescue(B)) continue;
        if (Provided(Earlier) == Provided(B)) @compileError(
            "zrx: dependency type `" ++ @typeName(Provided(B)) ++ "` is provided twice, by " ++ describe(Earlier) ++ " and by " ++ describe(B) ++
                "; keep one of them, or have one provide a distinct struct type",
        );
    };
    return @Tuple(list);
}

fn describe(comptime B: type) []const u8 {
    return if (isResource(B)) "`" ++ @typeName(B) ++ "`" else "a value";
}

/// An environment handed on as it is: every element is a value, whatever
/// its type looks like. A system gives its programs what it resolved this
/// way; sorting those values into values and resources a second time would
/// take a value that has the shape of a binding for a binding. `rescued`
/// says whether a rescue already stands outside: a program's own is then
/// left out, as a default is that `run` replaces.
pub fn Resolved(comptime Env: type, comptime is_rescued: bool) type {
    return struct {
        env: Env,

        pub const zrx_resolved: Mark = .{};
        pub const rescued = is_rescued;
    };
}

pub fn resolved(env: anytype, comptime rescued: bool) Resolved(@TypeOf(env), rescued) {
    return .{ .env = env };
}

fn isResolved(comptime Given: type) bool {
    return isMarked(Given, "zrx_resolved");
}

/// Positions in `defaults ++ given`: the values, then the resources in the
/// order they are acquired, and the rescue that stands outside them all.
const Plan = struct {
    values: []const usize,
    resources: []const usize,
    rescue: ?usize,
};

/// Plain values come first. Then, again and again, the first resource in
/// written order whose needs are all there. A default whose type is also
/// given is left out: it is neither provided nor acquired. A rescue is
/// neither a value nor a resource and takes no part in the order: one that
/// is given replaces a default one, and so does one that already stands
/// outside (`rescued`).
fn plan(comptime Defaults: type, comptime Given: type, comptime given_values: bool, comptime rescued: bool) Plan {
    @setEvalBranchQuota(di.quota);
    const given = if (given_values) di.types(Given) else di.types(Bindings(Given));
    const all = di.types(Defaults) ++ given;
    const overridable = di.types(Defaults).len;

    var values: []const usize = &.{};
    var pending: []const usize = &.{};
    var available: []const type = &.{};
    var guard: ?usize = null;
    next: for (all, 0..) |B, i| {
        // In a resolved environment every element is a value.
        const bound = i < overridable or !given_values;
        if (bound and isRescue(B)) {
            if (i >= overridable or (guard == null and !rescued)) guard = i;
            continue :next;
        }
        if (i < overridable) for (given) |Over| {
            if ((if (given_values) Over else Provided(Over)) == Provided(B)) continue :next;
        };
        if (bound and isResource(B)) {
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
    return .{ .values = values, .resources = resources, .rescue = guard };
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

/// Calls `program.call(env, rescued)` with the environment built from
/// `given` and from the `defaults` it does not replace. Resources are held
/// around the call and released in the reverse of the order they were
/// acquired in. A rescue among the bindings stands outside all of that: it
/// is given what the call or a resource failed with, after the release.
/// `rescued` tells the body whether a rescue stands outside it.
pub fn run(defaults: anytype, given: anytype, program: anytype) !void {
    const Given = @TypeOf(given);
    if (comptime isResolved(Given)) return runWith(defaults, given.env, true, Given.rescued, program);
    return runWith(defaults, given, false, false, program);
}

fn runWith(defaults: anytype, given: anytype, comptime given_values: bool, comptime rescued: bool, program: anytype) !void {
    const Defaults = @TypeOf(defaults);
    const Given = @TypeOf(given);
    const order = comptime plan(Defaults, Given, given_values, rescued);
    const types = comptime di.types(Defaults) ++ di.types(Given);
    const all: @Tuple(types) = defaults ++ given;

    const Values = comptime values: {
        var list: [order.values.len]type = undefined;
        for (order.values, 0..) |i, at| list[at] = types[i];
        break :values @Tuple(&list);
    };
    var env: Values = undefined;
    inline for (order.values, 0..) |i, at| env[at] = all[i];

    if (comptime order.rescue == null) return hold(order.resources, all, env, program, rescued);
    const guard = all[comptime order.rescue.?];
    const Possible = @typeInfo(@TypeOf(hold(order.resources, all, env, program, true))).error_union.error_set;
    comptime @TypeOf(guard).check(Values, Possible, held: {
        var list: []const type = &.{};
        for (order.resources) |i| list = list ++ [_]type{types[i].Provides};
        break :held list;
    });
    return hold(order.resources, all, env, program, true) catch |err| guard.handle(env, err);
}

fn hold(comptime rest: []const usize, all: anytype, env: anytype, program: anytype, comptime rescued: bool) !void {
    if (rest.len == 0) return program.call(env, rescued);
    const binding = all[rest[0]];
    const Next = struct {
        all: @TypeOf(all),
        env: @TypeOf(env),
        program: @TypeOf(program),

        pub fn call(self: @This(), value: @TypeOf(binding).Provides) !void {
            return hold(rest[1..], self.all, di.extend(self.env, value), self.program, rescued);
        }
    };
    return binding.bind(env, Next{ .all = all, .env = env, .program = program });
}
