// One catalog drives both cross-compilation and code-generation comparisons.
pub const targets = [_][]const u8{
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "aarch64-macos",
    "x86_64-windows-gnu",
    "aarch64-windows-msvc",
    "wasm32-freestanding",
};

// Each case requires exported <case>_direct, <case>_grouped, and <case>_separate
// functions in cases.zig, plus <case>_test() for native behavior checks. The IR
// checker constructs symbol names from this catalog; declaration order is irrelevant.
pub const cases = [_][]const u8{
    "arithmetic",
    "type_transition",
    "vector_map",
};

// Loop SSA names/order can differ even when final instructions match. Restrict
// assembly comparisons to AArch64: x86/Wasm also differ in register allocation
// and scheduling. Those variants retain native behavior/cross-build coverage.
pub const assembly_cases = .{
    .{ .name = "each_sum", .arch = "aarch64" },
};

// Optional construction does not currently match the hand-written scalar branch
// in the pinned compiler's optimized IR. Keep native behavior and cross builds
// covered without claiming identical code or weakening the strict comparator.
pub const behavior_only_cases = [_][]const u8{"keep_if"};

// These exercise additional API contracts on every target without asserting
// identical LLVM bodies for imperative loops and lazy adapters.
pub const cross_only = .{
    .{ .name = "sequences", .path = "tests/cross/sequences.zig" },
};
