const std = @import("std");
const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

// KMAC fills a slice of any length and has a `mac_length`, not a
// `digest_length`: nothing says how many bytes its digest is.
const KMac128 = bytes.digest(started: {
    // Its `init` absorbs the key, which takes more than the default quota.
    @setEvalBranchQuota(100_000);
    break :started std.crypto.hash.sha3.KMac128.init("key");
});

fn ignore(_: anytype) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(KMac128{}, KMac128.update), zrx.map(KMac128.final), zrx.forEach(ignore) }).run(.{});
}
