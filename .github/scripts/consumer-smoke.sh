#!/usr/bin/env bash
# Builds and runs the quickstart in a new project that depends on zrx the
# way the README says: `zig fetch --save=zrx <source>`, then
# `b.dependency("zrx", ...).module("zrx")`. The package cache starts empty.
#
#   consumer-smoke.sh <url or path of a source archive>
#
# Prints the hash the dependency was saved with.
set -euo pipefail

source=$1
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export ZIG_GLOBAL_CACHE_DIR="$work/cache"
mkdir -p "$work/consumer/src"
cd "$work/consumer"
cp "$repo/.zigversion" .
cp "$repo/examples/quickstart.zig" src/main.zig

cat > build.zig.zon <<'EOF'
.{
    .name = .consumer,
    .version = "0.0.0",
    .fingerprint = 0x705b37271c0ffee0,
    .minimum_zig_version = "0.17.0",
    .paths = .{""},
}
EOF

cat > build.zig <<'EOF'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zrx = b.dependency("zrx", .{ .target = target, .optimize = optimize }).module("zrx");
    const exe = b.addExecutable(.{
        .name = "quickstart",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    b.step("run", "Run the quickstart").dependOn(&b.addRunArtifact(exe).step);
}
EOF

zig fetch --save=zrx "$source" >&2
if ! output=$(zig build run 2>&1); then
    printf '%s\n' "$output" >&2
    exit 1
fi
if [ "$output" != "total: 14" ]; then
    printf 'expected "total: 14", got:\n%s\n' "$output" >&2
    exit 1
fi
sed -n 's/^ *\.hash = "\(.*\)",$/\1/p' build.zig.zon
