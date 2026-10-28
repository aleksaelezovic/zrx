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
// functions in cases.zig. The checker and native fixture test construct these
// names from this catalog; declaration order does not matter.
pub const cases = [_][]const u8{
    "arithmetic",
    "type_transition",
};
