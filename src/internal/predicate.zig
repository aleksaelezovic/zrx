//! Private identity for static typed predicate compositions.
pub const Tag = opaque {};

pub fn isPredicate(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "predicate_tag") and T.predicate_tag == Tag;
}
