const std = @import("std");
const app = @import("app");
const domain = app.jobs;
const allocator = std.testing.allocator;
const limit = domain.max_values;

test "configuration is explicit finite by default and validates every limit" {
    const settings = try app.commands.Config.fromArgs(&.{ "serve", "0", "5", "2", "128", "3" });
    try std.testing.expectEqual(@as(?usize, 5), settings.connections);
    try std.testing.expectEqual(@as(usize, 2), settings.max_jobs);
    try std.testing.expectEqual(@as(usize, 128), settings.body_bytes);
    try std.testing.expectEqual(@as(usize, 3), settings.max_values);
    try std.testing.expectEqual(@as(?usize, null), (try app.commands.Config.fromArgs(&.{ "live", "8080" })).connections);
    try std.testing.expectError(error.ExpectedServePortCountOrLivePort, app.commands.Config.fromArgs(&.{}));
    try std.testing.expectError(error.InvalidArgumentCount, app.commands.Config.fromArgs(&.{ "serve", "0" }));
    try std.testing.expectError(error.InvalidLimits, app.commands.Config.fromArgs(&.{ "serve", "0", "1", "0" }));
    try std.testing.expectError(error.InvalidLimits, app.commands.Config.fromArgs(&.{ "serve", "0", "1", "1025" }));
    try std.testing.expectError(error.InvalidLimits, app.commands.Config.fromArgs(&.{ "serve", "0", "1", "1", "4097" }));
    try std.testing.expectError(error.InvalidLimits, app.commands.Config.fromArgs(&.{ "serve", "0", "1", "1", "128", "17" }));
    try std.testing.expectError(error.Overflow, app.commands.Config.fromArgs(&.{ "serve", "65536", "1" }));
}

test "validation bounds and copies the submitted record" {
    var label = [_]u8{ 'a', 'b' };
    var values = [_]i32{ -1_000_000, 1_000_000, 7 };
    const job = try domain.validate(limit, .{ .label = &label, .values = &values });
    @memset(&label, 'x');
    @memset(&values, 0);
    try std.testing.expectEqualStrings("ab", job.labelText());
    try std.testing.expectEqual(@as(i64, 7), job.result);
    try std.testing.expectEqual(@as(i32, -1_000_000), job.values[0]);
    inline for (.{ "", "bad label", "quote\"", "abcdefghijklmnopqrstuvwxyz1234567" }) |bad|
        try std.testing.expectError(error.InvalidJob, domain.validate(limit, .{ .label = bad, .values = &.{1} }));
    try std.testing.expectError(error.InvalidJob, domain.validate(limit, .{ .label = "ok", .values = &.{} }));
    try std.testing.expectError(error.InvalidJob, domain.validate(limit, .{ .label = "ok", .values = &.{1_000_001} }));
    try std.testing.expectError(error.InvalidJob, domain.validate(1, .{ .label = "ok", .values = &.{ 1, 2 } }));
    const maximum = try domain.validate(limit, .{ .label = "abcdefghijklmnopqrstuvwxyz123456", .values = &@as([16]i32, @splat(1_000_000)) });
    try std.testing.expectEqual(@as(i64, 16_000_000), maximum.result);
}

test "strict JSON rejects malformed schema coercions and duplicates" {
    const job = try domain.decode(allocator, limit, "{\"label\":\"sum-1\",\"values\":[1,2]}");
    try std.testing.expectEqual(@as(i64, 3), job.result);
    inline for (.{
        "",
        "[]",
        "null",
        "{",
        "{\"label\":\"x\"}",
        "{\"label\":\"x\",\"values\":[],\"unknown\":1}",
        "{\"label\":\"x\",\"label\":\"y\",\"values\":[1]}",
        "{\"label\":1,\"values\":[1]}",
        "{\"label\":\"x\",\"values\":[\"1\"]}",
        "{\"label\":\"x\",\"values\":[1.5]}",
        "{\"label\":\"x\",\"values\":[true]}",
        "{\"label\":\"x\",\"values\":[2147483648]}",
        "{\"label\":\"x\",\"values\":[1]} trailing",
    }) |bad| try std.testing.expectError(error.InvalidJob, domain.decode(allocator, limit, bad));
}

fn decodeFixture(a: std.mem.Allocator) !void {
    _ = try domain.decode(a, limit, "{\"label\":\"sum-1\",\"values\":[1,2]}");
}

test "JSON allocation failures propagate as infrastructure errors and free partial parsing" {
    try std.testing.checkAllAllocationFailures(allocator, decodeFixture, .{});
}

test "bounded store has stable IDs full is nonmutating and lookup is copied" {
    var store = try app.store.Store.init(allocator, 1);
    defer store.deinit(allocator);
    const job = try domain.validate(limit, .{ .label = "job", .values = &.{ 2, 3 } });
    try std.testing.expectError(error.NotFound, store.lookup(0));
    try std.testing.expectError(error.NotFound, store.lookup(1));
    try std.testing.expectEqual(@as(u64, 1), (try store.submit(job)).id);
    try std.testing.expectError(error.StoreFull, store.submit(job));
    try std.testing.expectEqual(@as(usize, 1), store.len);
    try std.testing.expectEqual(@as(i64, 5), (try store.lookup(1)).job.result);
    try std.testing.expectError(error.NotFound, store.lookup(std.math.maxInt(u64)));
}

test "job identifiers and content type policy are deliberately narrow" {
    try std.testing.expectEqual(@as(u64, 12), try app.routes.jobId("12"));
    inline for (.{ "/jobs/0", "/jobs/01", "/jobs/-1", "/jobs/1?x=y", "/jobs/", "/jobs/18446744073709551616" }) |bad|
        try std.testing.expectError(error.InvalidId, app.routes.jobId(bad["/jobs/".len..]));
    try std.testing.expect(app.routes.acceptsJson("Application/JSON", false));
    try std.testing.expect(!app.routes.acceptsJson(null, false));
    try std.testing.expect(!app.routes.acceptsJson("application/json; charset=utf-8", false));
    try std.testing.expect(!app.routes.acceptsJson("application/json", true));
}
