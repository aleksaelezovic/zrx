const std = @import("std");
const declarations = @import("../data/declarations.zig");
const seq = @import("../data/sequences.zig");
const cb = @import("../internal/callbacks.zig");
const composition = @import("../internal/composition.zig");
const transforms = @import("../internal/transforms.zig");

/// Explicit stop-or-delay decision. Zero milliseconds retries immediately,
/// with a cancellation poll; a positive delay uses run's Io and awake clock.
pub const RetryDecision = union(enum) {
    stop,
    retry_after_ms: u64,
};

/// max_attempts includes the initial attempt. null explicitly allows unlimited
/// attempts; zero fails before acquisition/activation. Fixed policy retries every
/// operation error except cancellation. Use a function for error classification.
pub const RetryOptions = struct {
    max_attempts: ?usize,
    delay_ms: u64 = 0,
};

/// Cold, serial, per-item retry boundary over a flat nonempty tuple of built-in map/each
/// and tap operators (including their grouped callback forms). Other operators
/// belong outside the attempt: no stateful singleton-pipeline reinterpretation.
///
/// Every attempt restarts from the original shallow input. On success emit the
/// final payload as E!T data; on policy stop emit the last operation error as
/// E!T data. Following items continue. Counts reset per item/run and saturate at
/// maxInt(usize). Sharing by stable reference evaluates one retry boundary.
///
/// Policy is RetryOptions/an options literal, or a comptime-known typed
/// fn (services..., OperationError, usize) RetryDecision. Leading parameters
/// follow normal DI; error and retry_count are ordinary data. retry_count is zero
/// on the first failure and counts retries already performed. No hidden cap or
/// extra predicate applies to function policies. u64 millisecond delays convert
/// losslessly to the standard Io duration representation.
///
/// Cancellation is never policy input or item data. Poll even for zero delay.
/// Source, acquisition and downstream errors retain normal run failure behavior.
/// An indefinite retry backpressures following items; no new worker/queue is
/// implied. Request-scoped HTTP lanes are unsupported in this first milestone.
///
/// Repeated calls can repeat effects. No rollback, memoization, persisted counts,
/// stage checkpoints, durable recovery or exactly-once effects are provided.
/// Applications own idempotency and safe replay of borrowed/mutable referents.
/// Callbacks own partial cleanup; no intermediate destructors are inferred.
pub fn retryPipe(source: anytype, operators: anytype, policy: anytype) Description(@TypeOf(source), @TypeOf(operators), PolicyIdentity(@TypeOf(.{policy}))) {
    const P = @TypeOf(.{policy});
    return .{
        .source = source,
        .operators = operators,
        .policy = if (comptime functionPolicy(P)) .{policy} else options(policy),
    };
}

fn functionPolicy(comptime P: type) bool {
    return @typeInfo(@typeInfo(P).@"struct".field_types[0]) == .@"fn";
}
fn PolicyIdentity(comptime P: type) type {
    return if (functionPolicy(P)) P else @Tuple(&.{RetryOptions});
}
fn options(spec: anytype) RetryOptions {
    const T = @TypeOf(spec);
    if (comptime @typeInfo(T) != .@"struct" or composition.isTuple(T))
        @compileError("retryPipe: policy must be options or a comptime-known function");
    inline for (@typeInfo(T).@"struct".field_names) |field| {
        if (comptime !std.mem.eql(u8, field, "max_attempts") and !std.mem.eql(u8, field, "delay_ms"))
            @compileError("retryPipe: unknown fixed policy option " ++ field);
    }
    if (!@hasField(T, "max_attempts"))
        @compileError("retryPipe: fixed policy must specify max_attempts (null for unlimited)");
    return .{
        .max_attempts = spec.max_attempts,
        .delay_ms = if (@hasField(T, "delay_ms")) spec.delay_ms else 0,
    };
}

fn Description(comptime Source: type, comptime Operators: type, comptime P: type) type {
    declarations.requireSource(Source);
    const Meta = Attempt(seq.Item(Source), Operators);
    const is_function = functionPolicy(P);
    const policy_fn = if (is_function) @as(P, undefined)[0] else {};
    if (is_function) {
        if (cb.Info(policy_fn, 2).Return != RetryDecision)
            @compileError("retryPipe: policy must return RetryDecision");
        cb.validate(policy_fn, &.{ Meta.Errors, usize });
    }
    const PolicyServices = if (is_function) &cb.Info(policy_fn, 2).Services else &.{};
    const LocalServices = declarations.concat(&Meta.Services, PolicyServices);
    return struct {
        source: Source,
        operators: Operators,
        policy: if (is_function) P else RetryOptions,
        pub const graph_tag = seq.GraphTag;
        pub const sequence_tag = seq.SequenceTag;
        pub const node_kind = .retry;
        pub const Item = Meta.Result;
        pub const Requirements = declarations.concat(declarations.requirements(Source), &LocalServices);
        pub const retry_meta = struct {
            pub fn validate(policy: if (is_function) P else RetryOptions) !void {
                if (!is_function) {
                    if (policy.max_attempts == 0) return error.InvalidRetryAttempts;
                }
            }
            pub fn run(operators: Operators, policy: if (is_function) P else RetryOptions, env: anytype, original: seq.Item(Source), output: *Meta.Result) std.Io.Cancelable!void {
                var retries: usize = 0;
                while (true) {
                    try env.io().checkCancel();
                    if (Meta.run(operators, env, original)) |value| {
                        try env.io().checkCancel();
                        output.* = value;
                        return;
                    } else |err| {
                        if (@as(anyerror, err) == error.Canceled) return error.Canceled;
                        try env.io().checkCancel();
                        const decision: RetryDecision = if (is_function)
                            cb.invoke(policy_fn, env, .{ err, retries })
                        else if (policy.max_attempts != null and retries >= policy.max_attempts.? - 1)
                            .stop
                        else
                            .{ .retry_after_ms = policy.delay_ms };
                        try env.io().checkCancel();
                        switch (decision) {
                            .stop => {
                                output.* = err;
                                return;
                            },
                            .retry_after_ms => |delay| {
                                if (delay != 0)
                                    try env.io().sleep(.fromNanoseconds(@as(i96, delay) * std.time.ns_per_ms), .awake);
                                retries +|= 1;
                            },
                        }
                    }
                }
            }
        };
    };
}

fn validateStages(comptime Input: type, comptime Operators: type, comptime index: usize) void {
    const stages = @typeInfo(Operators).@"struct".field_types;
    const Stage = stages[index];
    if (!@hasDecl(Stage, "transform_tag") or Stage.transform_tag != declarations.Tag or
        (Stage.callback_operation != .map and Stage.callback_operation != .tap))
        @compileError("retryPipe: attempts support only map/each and tap");
    const Next = stages[index].Output(Input);
    if (!@hasDecl(Next, "node_kind") or (Next.node_kind != .map and Next.node_kind != .tap))
        @compileError("retryPipe: attempts support only map/each and tap");
    if (index + 1 < stages.len) validateStages(Next, Operators, index + 1);
}
fn stageErrors(comptime Input: type, comptime Operators: type, comptime index: usize) type {
    const stages = @typeInfo(Operators).@"struct".field_types;
    const Next = stages[index].Output(Input);
    const E = transforms.Errors(Next.functions);
    return if (index + 1 == stages.len) E else E || stageErrors(Next, Operators, index + 1);
}
// Type-only input for the ordinary operator typing rule. No singleton source is
// constructed or executed for an attempt.
fn ItemDeclaration(comptime Element: type) type {
    return struct {
        pub const graph_tag = seq.GraphTag;
        pub const sequence_tag = seq.SequenceTag;
        pub const Item = Element;
        pub const Requirements: [0]type = .{};
    };
}
fn Attempt(comptime Input: type, comptime Operators: type) type {
    const Start = ItemDeclaration(Input);
    const End = composition.PipelineOutput(Start, Operators);
    comptime validateStages(Start, Operators, 0);
    return struct {
        pub const Payload = seq.Item(End);
        pub const Errors = stageErrors(Start, Operators, 0);
        pub const Result = Errors!Payload;
        pub const Services = declarations.concat(declarations.requirements(End), &.{});
        pub fn run(operators: Operators, env: anytype, value: Input) Result {
            return compose(operators, env, value, 0);
        }
        fn compose(operators: Operators, env: anytype, value: anytype, comptime index: usize) Result {
            const Step = @TypeOf(operators[index]).Output(ItemDeclaration(@TypeOf(value)));
            const next = if (Step.node_kind == .map)
                try transforms.map(Step.functions, env, value, 0)
            else
                try transforms.tap(Step.functions, env, value);
            return if (index + 1 == operators.len) next else try compose(operators, env, next, index + 1);
        }
    };
}
