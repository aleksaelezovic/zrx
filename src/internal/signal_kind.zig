// Type-only signal metadata, kept independent of executors and composition.
pub const Tag = opaque {};
pub const ValuesTag = opaque {};
pub const SampleTag = opaque {};

pub fn Target(comptime T: type) type {
    return if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one)
        @typeInfo(T).pointer.child
    else
        T;
}

pub fn isSignal(comptime T: type) bool {
    const D = Target(T);
    return @typeInfo(D) == .@"struct" and @hasDecl(D, "signal_tag") and D.signal_tag == Tag;
}

pub fn Value(comptime T: type) type {
    if (!isSignal(T)) @compileError("signal: expected a signal declaration; use hold(initial) on an update source");
    return Target(T).Value;
}

pub fn isValues(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "signal_values_tag") and T.signal_values_tag == ValuesTag;
}

pub fn isSample(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "signal_sample_tag") and T.signal_sample_tag == SampleTag;
}
