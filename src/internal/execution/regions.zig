//! A maximal by-value synchronous chain is one typed cursor region. References
//! retain explicit graph identity; their shared materialization is run-owned.
const decl = @import("../../data/declarations.zig");
const seq = @import("../../data/sequences.zig");
const cursors = @import("cursors.zig");
const signals = @import("../signal_kind.zig");

// Request-scoped HTTP values must not cross retention/stateful region stages.
pub fn httpSafe(comptime T: type) bool {
    if (comptime !inlineNode(T)) return true;
    if (@hasDecl(T, "node_kind")) {
        if (T.node_kind != .map and T.node_kind != .filter and T.node_kind != .tap)
            return false;
    } else if (T.declaration_kind != .taken) return false;
    return httpSafe(@FieldType(T, "source"));
}

pub fn inlineNode(comptime T: type) bool {
    if (@typeInfo(T) == .pointer) return false;
    if (signals.isSignal(T)) return false;
    if (@hasDecl(T, "node_kind"))
        return T.node_kind == .map or T.node_kind == .filter or T.node_kind == .tap or T.node_kind == .fold or T.node_kind == .scan or
            T.node_kind == .take or T.node_kind == .bounded;
    return @hasDecl(T, "declaration_kind") and (T.declaration_kind == .taken or T.declaration_kind == .bounded);
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
        pub const node_kind = if (@hasDecl(Original, "node_kind")) Original.node_kind else if (Original.declaration_kind == .taken) .take else .bounded;
        pub const declaration_kind = if (@hasDecl(Original, "declaration_kind")) Original.declaration_kind else {};
        pub const functions = if (@hasDecl(Original, "functions")) Original.functions else .{};
        pub const callback = if (@hasDecl(Original, "callback")) Original.callback else {};
        source: Source,
        seed: if (@hasField(Original, "seed")) @FieldType(Original, "seed") else void,
        limit: usize,
    };
}

pub fn rebase(original: anytype, boundary: anytype) Rebased(@TypeOf(original), @TypeOf(boundary)) {
    if (comptime !inlineNode(@TypeOf(original))) return boundary;
    return .{
        .source = rebase(original.source, boundary),
        .seed = if (comptime @hasField(@TypeOf(original), "seed")) original.seed else {},
        .limit = if (comptime @hasField(@TypeOf(original), "limit")) original.limit else 0,
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
