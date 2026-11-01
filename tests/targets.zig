//! One target/fixture catalog. These instantiate the current public API and emit
//! objects; they do not execute foreign targets or assert imperative code equality.
pub const targets = [_][]const u8{
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "aarch64-macos",
    "x86_64-windows-gnu",
    "aarch64-windows-msvc",
    "wasm32-freestanding",
};
const Fixture = struct { name: []const u8, path: []const u8, requires_hosted: bool = false };
pub const fixtures = [_]Fixture{
    .{ .name = "declarations", .path = "tests/cross/declarative.zig" },
    .{ .name = "scan", .path = "tests/cross/declarative_scan.zig" },
    .{ .name = "operators", .path = "tests/cross/operators.zig" },
    .{ .name = "branch", .path = "tests/cross/branch.zig" },
    .{ .name = "line-io", .path = "tests/cross/declarative_io.zig", .requires_hosted = true },
    .{ .name = "http", .path = "tests/cross/http.zig", .requires_hosted = true },
};
