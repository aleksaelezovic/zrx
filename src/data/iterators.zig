const composition = @import("../internal/composition.zig");
const sequences = @import("sequences.zig");

/// Borrow a mutable single-item iterator pointer with next(self) returning ?T
/// or E!?T. Construction calls nothing; new cursors share the borrowed position
/// instead of rewinding/cloning. Do not concurrently use unsynchronized copies.
/// Source errors are distinct from error-valued items. Infallible finite inputs
/// can feed folds; terminal effects are deferred until run.
pub fn fromIterator(input: anytype) sequences.PullView(BorrowedCursor(@TypeOf(input))) {
    return .{ .input = .{ .input = input } };
}

fn BorrowedCursor(comptime Pointer: type) type {
    const contract = "fromIterator: expected a mutable single-item pointer to an iterator with next(self) returning ?T or E!?T";
    if (@typeInfo(Pointer) != .pointer or @typeInfo(Pointer).pointer.size != .one or
        @typeInfo(Pointer).pointer.attrs.@"const")
        @compileError(contract);
    const Input = @typeInfo(Pointer).pointer.child;
    if (@typeInfo(Input) != .@"struct" or !@hasDecl(Input, "next"))
        @compileError(contract);
    const info = switch (@typeInfo(@TypeOf(Input.next))) {
        .@"fn" => |info| info,
        else => @compileError(contract),
    };
    if (info.is_generic or info.attrs.varargs or info.param_types.len != 1 or
        info.param_types[0] != Pointer or info.return_type == null)
        @compileError(contract);
    const Return = info.return_type.?;
    const Payload = composition.Payload(Return);
    if (@typeInfo(Payload) != .optional) @compileError(contract);
    return struct {
        input: Pointer,

        pub fn next(self: *@This()) Return {
            return self.input.next();
        }
    };
}
