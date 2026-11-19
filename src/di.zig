//! Type-keyed dependency injection, resolved entirely at compile time.
//!
//! An *environment* is a tuple of runtime values; the exact type of each value
//! is its key. A *handler* is a comptime-known function whose leading
//! parameters are dependencies (looked up by type) and whose trailing
//! parameters are the data an operator hands it:
//!
//!     fn scale(factor: Scale, value: u32) u32 { ... }
//!     //       ^ injected     ^ stream item
//!
//! Nothing here exists at runtime: a bound handler stores exactly the
//! dependencies it asked for and calls the function directly.
const std = @import("std");

/// Comptime work grows with the size of a pipeline; every entry point that
/// reflects on one raises the default evaluation budget to this.
pub const quota = 1_000_000;

// ---------------------------------------------------------------------------
// Environments
// ---------------------------------------------------------------------------

pub fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
}

/// The dependency types of an environment, in order.
pub fn types(comptime Env: type) []const type {
    return @typeInfo(Env).@"struct".field_types;
}

pub fn indexOf(comptime Env: type, comptime T: type) ?usize {
    for (types(Env), 0..) |Have, i| if (Have == T) return i;
    return null;
}

pub fn has(comptime Env: type, comptime T: type) bool {
    return indexOf(Env, T) != null;
}

/// The dependency of type `T`. Callers check `has` first to report a good error.
pub fn get(env: anytype, comptime T: type) T {
    return env[comptime indexOf(@TypeOf(env), T).?];
}

/// The validated tuple type for the bindings a user passes to `run` or `provide`.
pub fn Normalized(comptime Deps: type) type {
    @setEvalBranchQuota(quota);
    if (!isTuple(Deps)) @compileError("zrx: dependencies must be a tuple such as `.{ io, logger }`, got `" ++ @typeName(Deps) ++ "`");
    const field_types = types(Deps);
    for (field_types, 0..) |T, i| {
        switch (@typeInfo(T)) {
            .type, .comptime_int, .comptime_float, .enum_literal, .null, .undefined, .noreturn, .void => @compileError(
                "zrx: dependency " ++ std.fmt.comptimePrint("{d}", .{i}) ++ " has type `" ++ @typeName(T) ++
                    "`; a dependency is a runtime value keyed by its type, so give it a named type",
            ),
            else => {},
        }
        for (field_types[0..i]) |Earlier| if (Earlier == T) @compileError(
            "zrx: dependency type `" ++ @typeName(T) ++ "` is provided twice; wrap one in a distinct struct type to tell them apart",
        );
    }
    return @Tuple(field_types);
}

/// `Env` with `T` added, or unchanged when `T` is already a key (the new value shadows it).
pub fn Extend(comptime Env: type, comptime T: type) type {
    @setEvalBranchQuota(quota);
    if (has(Env, T)) return Env;
    return @Tuple(types(Env) ++ [_]type{T});
}

pub fn extend(env: anytype, value: anytype) Extend(@TypeOf(env), @TypeOf(value)) {
    const Env = @TypeOf(env);
    const T = @TypeOf(value);
    var out: Extend(Env, T) = undefined;
    inline for (0..comptime types(Env).len) |i| out[i] = env[i];
    out[comptime indexOf(Env, T) orelse types(Env).len] = value;
    return out;
}

/// "`A`, `B`" for diagnostics.
pub fn listTypes(comptime list: []const type) []const u8 {
    if (list.len == 0) return "(nothing)";
    var text: []const u8 = "";
    for (list, 0..) |T, i| text = text ++ (if (i == 0) "" else ", ") ++ "`" ++ @typeName(T) ++ "`";
    return text;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// A composite handler is a struct type built from other handlers:
///
///     pub const zrx_handler = {};
///     pub fn requires(comptime arity: usize) []const type
///     pub fn call(env: anytype, args: anytype) R
///
/// `env` holds at least the types `requires` returned; `args` is the tuple of
/// trailing data. Use `invoke` inside `call` to run child handlers.
fn isComposite(comptime handler: anytype) bool {
    if (@TypeOf(handler) != type) return false;
    return @typeInfo(handler) == .@"struct" and @hasDecl(handler, "zrx_handler");
}

pub fn isHandler(comptime handler: anytype) bool {
    return @typeInfo(@TypeOf(handler)) == .@"fn" or isComposite(handler);
}

fn describe(comptime handler: anytype) []const u8 {
    return if (@TypeOf(handler) == type) @typeName(handler) else @typeName(@TypeOf(handler));
}

fn expectHandler(comptime who: []const u8, comptime handler: anytype, comptime arity: usize) void {
    if (!isHandler(handler)) @compileError(who ++ ": expected a handler (a comptime-known function), got `" ++ describe(handler) ++ "`");
    if (isComposite(handler)) return;
    const info = @typeInfo(@TypeOf(handler)).@"fn";
    if (info.attrs.varargs) @compileError(who ++ ": handler `" ++ describe(handler) ++ "` must not be variadic");
    if (info.return_type == type) @compileError(
        who ++ ": `" ++ describe(handler) ++ "` returns a handler and is not one itself; call it and pass what it returns, as in `field(.name)`",
    );
    if (info.param_types.len < arity) @compileError(std.fmt.comptimePrint(
        "{s}: handler `{s}` must end with {d} data parameter(s); dependencies come before them",
        .{ who, describe(handler), arity },
    ));
    for (info.param_types[0 .. info.param_types.len - arity]) |T| if (T == null) @compileError(
        who ++ ": handler `" ++ describe(handler) ++ "` has an untyped dependency parameter; only trailing data parameters may be `anytype`",
    );
}

/// The dependency types `handler` asks for, given it ends with `arity` data parameters.
pub fn requires(comptime who: []const u8, comptime handler: anytype, comptime arity: usize) []const type {
    @setEvalBranchQuota(quota);
    expectHandler(who, handler, arity);
    if (isComposite(handler)) return handler.requires(arity);
    const params = @typeInfo(@TypeOf(handler)).@"fn".param_types;
    var out: []const type = &.{};
    for (params[0 .. params.len - arity]) |T| out = merge(out, &.{T.?});
    return out;
}

/// Set union of dependency lists, keeping first-seen order.
pub fn merge(comptime a: []const type, comptime b: []const type) []const type {
    var out = a;
    next: for (b) |T| {
        for (out) |Have| if (Have == T) continue :next;
        out = out ++ [_]type{T};
    }
    return out;
}

/// The declared type of trailing data parameter `i`, or null when it is `anytype`.
pub fn Param(comptime handler: anytype, comptime arity: usize, comptime i: usize) ?type {
    if (isComposite(handler)) return null;
    const params = @typeInfo(@TypeOf(handler)).@"fn".param_types;
    return params[params.len - arity + i];
}

/// Whether a value of type `Arg` may be passed where `Want` is declared.
/// Deliberately small: exact match, optional wrapping, and adding `const`.
pub fn accepts(comptime Want: type, comptime Arg: type) bool {
    if (Want == Arg) return true;
    switch (@typeInfo(Want)) {
        .optional => |optional| return accepts(optional.child, Arg),
        .error_set => |want| {
            if (@typeInfo(Arg) != .error_set) return false;
            const want_names = want.error_names orelse return true; // anyerror
            const arg_names = @typeInfo(Arg).error_set.error_names orelse return false;
            next: for (arg_names) |name| {
                for (want_names) |have| if (std.mem.eql(u8, have, name)) continue :next;
                return false;
            }
            return true;
        },
        .pointer => |want| {
            const arg = switch (@typeInfo(Arg)) {
                .pointer => |arg| arg,
                else => return false,
            };
            if (arg.attrs.@"const" and !want.attrs.@"const") return false;
            if (want.size == arg.size) return want.child == arg.child;
            if (want.size == .slice and arg.size == .one) return switch (@typeInfo(arg.child)) {
                .array => |array| array.child == want.child,
                else => false,
            };
            return false;
        },
        else => return false,
    }
}

/// Reports every way `handler` cannot be used with `Env` and data `Args`.
pub fn check(comptime who: []const u8, comptime handler: anytype, comptime Env: type, comptime Args: []const type) void {
    @setEvalBranchQuota(quota);
    for (requires(who, handler, Args.len)) |T| if (!has(Env, T)) @compileError(
        who ++ ": handler `" ++ describe(handler) ++ "` asks for dependency `" ++ @typeName(T) ++
            "`, which is not provided here; provided: " ++ listTypes(types(Env)) ++
            ". Pass it to `run(.{ ... })` or bind it with `program(...).provide(.{ ... })`.",
    );
    for (Args, 0..) |Arg, i| {
        const Want = Param(handler, Args.len, i) orelse continue;
        if (!accepts(Want, Arg)) @compileError(
            who ++ ": handler `" ++ describe(handler) ++ "` takes `" ++ @typeName(Want) ++
                "` but receives `" ++ @typeName(Arg) ++ "` here",
        );
    }
}

/// What `handler` returns for data of types `Args`.
pub fn Result(comptime who: []const u8, comptime handler: anytype, comptime Args: []const type) type {
    @setEvalBranchQuota(quota);
    const needs = requires(who, handler, Args.len);
    if (isComposite(handler))
        return @TypeOf(handler.call(@as(@Tuple(needs), undefined), @as(@Tuple(Args), undefined)));
    const info = @typeInfo(@TypeOf(handler)).@"fn";
    // A generic function's return type (an inferred error set included) only exists per instantiation.
    if (!info.is_generic) return info.return_type.?;
    const params = info.param_types;
    const leading = params.len - Args.len;
    var full: [params.len]type = undefined;
    for (params[0..leading], 0..) |T, i| full[i] = T.?;
    for (Args, leading..) |T, i| full[i] = T;
    return @TypeOf(@call(.auto, handler, @as(@Tuple(&full), undefined)));
}

/// `Result` without its error union, if any.
pub fn Payload(comptime R: type) type {
    return switch (@typeInfo(R)) {
        .error_union => |info| info.payload,
        else => R,
    };
}

fn ArgTypes(comptime Args: type) []const type {
    return types(Args);
}

/// Calls `handler`, taking its dependencies from `env` and its data from the tuple `args`.
pub fn invoke(comptime handler: anytype, env: anytype, args: anytype) Result("zrx", handler, ArgTypes(@TypeOf(args))) {
    if (comptime isComposite(handler)) return handler.call(env, args);
    const params = @typeInfo(@TypeOf(handler)).@"fn".param_types;
    const leading = params.len - args.len;
    comptime var full_types: [params.len]type = undefined;
    inline for (params[0..leading], 0..) |T, i| full_types[i] = T.?;
    inline for (0..args.len) |i| full_types[leading + i] = params[leading + i] orelse @TypeOf(args[i]);
    var full: @Tuple(&full_types) = undefined;
    inline for (params[0..leading], 0..) |T, i| full[i] = get(env, T.?);
    inline for (0..args.len) |i| full[leading + i] = args[i];
    return @call(.auto, handler, full);
}

/// `handler` with its dependencies taken out of `Env` once, ready to be called per item.
/// The stored tuple holds only what the handler asked for; a pure handler stores nothing.
pub fn Bound(comptime who: []const u8, comptime handler: anytype, comptime Env: type, comptime Args: []const type) type {
    @setEvalBranchQuota(quota);
    check(who, handler, Env, Args);
    const needs = requires(who, handler, Args.len);
    const Deps = @Tuple(needs);
    return struct {
        deps: Deps,

        pub const Return = Result(who, handler, Args);

        pub fn init(env: Env) @This() {
            var deps: Deps = undefined;
            inline for (needs, 0..) |T, i| deps[i] = get(env, T);
            return .{ .deps = deps };
        }

        pub fn call(self: *const @This(), args: @Tuple(Args)) Return {
            return invoke(handler, self.deps, args);
        }
    };
}
