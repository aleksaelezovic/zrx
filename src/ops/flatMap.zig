const declarations = @import("../data/declarations.zig");
const sequences = @import("../data/sequences.zig");
const callbacks = @import("../internal/callbacks.zig");
const composition = @import("../internal/composition.zig");
const cursors = @import("../internal/execution/cursors.zig");

/// Sequential expansion into cold synchronous declarations. The typed callback
/// is fn(services..., Item) Declaration or E!Declaration. Each selected child is
/// drained before the next outer item; empty outer input constructs no children.
/// Child bindings are planned/acquired with the enclosing run, not per item.
/// Supported children are by-value finite pull declarations (including
/// readChunks, readerLines and iterator adapters), not shared declaration references,
/// producers, merges, branches, signals or terminals.
/// No nested run, task, queue, dynamic subscription or resource scope is added.
///
/// Factory/child operation errors remain pending. Iterator/reader failures and
/// cancellation remain control. Borrowed storage returned by the callback must
/// outlive traversal; returning a description never extends referent lifetime.
/// For callback-produced arrays/Chunks, prefer map(factory), flatten(): it owns
/// the current value instead of borrowing a slice into a callback-local array.
pub fn flatMap(comptime factory: anytype) FlatMap(factory) {
    return .{};
}

fn FlatMap(comptime factory: anytype) type {
    const meta = callbacks.Info(factory, 1);
    const Argument = meta.Params[meta.Params.len - 1];
    if (@typeInfo(Argument) == .error_set or @typeInfo(Argument) == .error_union)
        @compileError("success operator: use recover or whenError for errors; wrap intentional error data in a record");
    const Child = composition.Payload(meta.Return);
    if (!sequences.isGraph(Child) or !synchronousChild(Child))
        @compileError("flatMap: callback must return a by-value finite synchronous declaration");
    if (@sizeOf(sequences.Item(Child)) == 0)
        @compileError("flatMap: child must have nonzero-sized items");
    return struct {
        pub fn Output(comptime Input: type) type {
            declarations.requireSource(Input);
            callbacks.validate(factory, &.{sequences.Item(Input)});
            return struct {
                pub const graph_tag = sequences.GraphTag;
                pub const sequence_tag = sequences.SequenceTag;
                pub const node_kind = .flat_map;
                pub const Item = sequences.Item(Child);
                pub const ChildSource = Child;
                pub const callback = factory;
                pub const Requirements = declarations.concat(
                    &declarations.concat(declarations.requirements(Input), &meta.Services),
                    declarations.requirements(Child),
                );
                source: Input,
            };
        }
        pub fn apply(_: @This(), input: anytype) Output(@TypeOf(input)) {
            return .{ .source = input };
        }
    };
}

fn synchronousChild(comptime Child: type) bool {
    if (@typeInfo(Child) == .pointer) return false;
    if (!cursors.finite(Child)) return false;
    if (Child.node_kind == .iterator) return true;
    return if (@hasField(Child, "source")) synchronousChild(@FieldType(Child, "source")) else true;
}
