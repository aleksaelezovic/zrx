//! A maximal by-value synchronous chain is one typed cursor region. References
//! retain explicit graph identity; their shared materialization is run-owned.
const decl = @import("../../data/declarations.zig");
const seq = @import("../../data/sequences.zig");
const cursors = @import("cursors.zig");
const signals = @import("../signal_kind.zig");

// Request-scoped HTTP values must not cross retention/stateful region stages.
pub fn httpSafe(comptime T: type) bool {
    if (comptime !inlineNode(T)) return true;
    if (T.node_kind != .map and T.node_kind != .filter and T.node_kind != .tap and T.node_kind != .take and T.node_kind != .recover)
        return false;
    return httpSafe(@FieldType(T, "source"));
}

pub fn inlineNode(comptime T: type) bool {
    if (@typeInfo(T) == .pointer) return false;
    if (signals.isSignal(T)) return false;
    if (@hasDecl(T, "node_kind"))
        return T.node_kind == .map or T.node_kind == .filter or T.node_kind == .tap or T.node_kind == .fold or T.node_kind == .scan or
            T.node_kind == .take or T.node_kind == .bounded or T.node_kind == .retry or T.node_kind == .recover or T.node_kind == .flat_map or
            T.node_kind == .flatten or T.node_kind == .split;
    return false;
}

pub fn Base(comptime T: type) type {
    return if (inlineNode(T)) Base(@FieldType(T, "source")) else T;
}

pub fn base(input: anytype) Base(@TypeOf(input)) {
    return if (comptime inlineNode(@TypeOf(input))) base(input.source) else input;
}

pub fn expandable(comptime Input: type) bool {
    const B = Base(Input);
    return @typeInfo(B) == .pointer and inlineNode(decl.Child(B));
}
pub fn Expanded(comptime Input: type) type {
    return Rebased(Input, decl.Child(Base(Input)));
}
pub fn expand(input: anytype) Expanded(@TypeOf(input)) {
    return rebase(input, base(input).*);
}

pub fn Rebased(comptime Original: type, comptime Boundary: type) type {
    if (!inlineNode(Original)) return Boundary;
    const Source = Rebased(@FieldType(Original, "source"), Boundary);
    return struct {
        pub const sequence_tag = seq.SequenceTag;
        pub const Item = seq.Item(Original);
        pub const node_kind = Original.node_kind;
        pub const functions = if (@hasDecl(Original, "functions")) Original.functions else .{};
        pub const callback = if (@hasDecl(Original, "callback")) Original.callback else {};
        pub const ChildSource = if (@hasDecl(Original, "ChildSource")) Original.ChildSource else void;
        pub const ErrorSet = if (@hasDecl(Original, "ErrorSet")) Original.ErrorSet else void;
        pub const retry_meta = if (@hasDecl(Original, "retry_meta")) Original.retry_meta else void;
        pub const split_options = if (@hasDecl(Original, "split_options")) Original.split_options else {};
        pub const matches = if (@hasDecl(Original, "matches")) Original.matches else {};
        source: Source,
        seed: if (@hasField(Original, "seed")) @FieldType(Original, "seed") else void,
        limit: usize,
        operators: if (@hasField(Original, "operators")) @FieldType(Original, "operators") else void,
        policy: if (@hasField(Original, "policy")) @FieldType(Original, "policy") else void,
    };
}

pub fn rebase(original: anytype, boundary: anytype) Rebased(@TypeOf(original), @TypeOf(boundary)) {
    if (comptime !inlineNode(@TypeOf(original))) return boundary;
    return .{
        .source = rebase(original.source, boundary),
        .seed = if (comptime @hasField(@TypeOf(original), "seed")) original.seed else {},
        .limit = if (comptime @hasField(@TypeOf(original), "limit")) original.limit else 0,
        .operators = if (comptime @hasField(@TypeOf(original), "operators")) original.operators else {},
        .policy = if (comptime @hasField(@TypeOf(original), "policy")) original.policy else {},
    };
}

pub fn View(comptime Input: type, comptime Env: type) type {
    return struct {
        pub const sequence_tag = seq.SequenceTag;
        pub const Item = seq.Item(Input);
        pub const Iterator = cursors.Cursor(Input, Env);
        input: Input,
        env: *Env,
        pub fn iterator(self: @This()) Iterator {
            return cursors.init(self.input, self.env);
        }
    };
}

pub fn view(original: anytype, boundary: anytype, env: anytype) View(Rebased(@TypeOf(original), @TypeOf(boundary)), @typeInfo(@TypeOf(env)).pointer.child) {
    return .{ .input = rebase(original, boundary), .env = env };
}
