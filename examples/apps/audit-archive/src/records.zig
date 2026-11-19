//! An audit export line, and the part of it that is archived.
const std = @import("std");
const zrx = @import("zrx");

pub const max_line = 1024;
pub const Line = zrx.Line(max_line);
pub const Resource = zrx.Line(96);
pub const Action = enum { read, create, update, delete };

/// What a line must hold. Its text borrows from the line being decoded.
const Entry = struct {
    id: u64,
    ts_ms: u64,
    action: Action,
    resource: []const u8,
    actor: []const u8,
    detail: ?[]const u8 = null,
};

/// The allowlist: only these fields are queued and archived. It owns its text.
pub const Record = struct {
    id: u64,
    ts_ms: u64,
    action: Action,
    resource: Resource,
};

const safe_bytes = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.";

/// Text with an escape in it is unescaped into the scratch buffer; a line
/// bounds how much there can be.
pub fn decode(line: Line) !Record {
    var scratch: [2 * max_line]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    const entry = try std.json.parseFromSliceLeaky(Entry, fixed.allocator(), line.text(), .{});
    return .{ .id = entry.id, .ts_ms = entry.ts_ms, .action = entry.action, .resource = try .from(entry.resource) };
}

/// A resource identifier is disclosed, so it may hold nothing surprising.
pub fn isSafe(resource: Resource) bool {
    return resource.len != 0 and std.mem.findNone(u8, resource.text(), safe_bytes) == null;
}

fn decoded(text: []const u8) !Record {
    return decode(try .from(text));
}

test "only the allowlisted fields are kept, with their text unescaped" {
    const record = try decoded(
        \\{"id":1,"ts_ms":2,"action":"read","resource":"port\u002d7","actor":"private","detail":"secret"}
    );
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}", .{std.json.fmt(record, .{})});
    try std.testing.expectEqualStrings(
        \\{"id":1,"ts_ms":2,"action":"read","resource":"port-7"}
    , writer.buffered());
}

test "a line that is not exactly one entry fails with the error std.json gives it" {
    try std.testing.expectError(error.SyntaxError, decoded(
        \\private payload
    ));
    try std.testing.expectError(error.UnknownField, decoded(
        \\{"id":1,"ts_ms":2,"action":"read","resource":"x","actor":"a","extra":true}
    ));
    try std.testing.expectError(error.DuplicateField, decoded(
        \\{"id":1,"id":2,"ts_ms":2,"action":"read","resource":"x","actor":"a"}
    ));
    try std.testing.expectError(error.MissingField, decoded(
        \\{"id":1,"ts_ms":2,"action":"read","resource":"x"}
    ));
    try std.testing.expectError(error.InvalidEnumTag, decoded(
        \\{"id":1,"ts_ms":2,"action":"purge","resource":"x","actor":"a"}
    ));
    try std.testing.expectError(error.Overflow, decoded(
        \\{"id":-1,"ts_ms":2,"action":"read","resource":"x","actor":"a"}
    ));
    try std.testing.expectError(error.UnexpectedToken, decoded(
        \\{"id":1,"ts_ms":2,"action":"read","resource":"x","actor":null}
    ));
    try std.testing.expectError(error.SyntaxError, decoded(
        \\{"id":1,"ts_ms":2,"action":"read","resource":"x","actor":"a"} {}
    ));
}

test "a resource is 1 to 96 safe bytes" {
    const longest: [96]u8 = @splat('r');
    const too_long: [97]u8 = @splat('r');
    try std.testing.expect(isSafe(try .from("node-7.eu_west")));
    try std.testing.expect(isSafe(try .from(&longest)));
    try std.testing.expectError(error.StreamTooLong, Resource.from(&too_long));
    inline for (.{ "", "a b", "x\ny", "caf\xc3\xa9", "a/b" }) |unsafe| {
        try std.testing.expect(!isSafe(try .from(unsafe)));
    }
}

test "the longest line of escaped text fits the scratch buffer" {
    const opening = "{\"id\":1,\"ts_ms\":2,\"action\":\"read\",\"resource\":\"r\",\"actor\":\"\\n";
    var line: [max_line]u8 = @splat('a');
    @memcpy(line[0..opening.len], opening);
    @memcpy(line[max_line - 2 ..], "\"}");
    _ = try decoded(&line);
}

// The README says so; std.json is looser than a schema would be.
test "what std.json takes besides the plain spelling" {
    const record = try decoded(
        \\{"id":"7","ts_ms":2.0,"action":3,"resource":[120,45,49],"actor":"","detail":null}
    );
    try std.testing.expectEqual(@as(u64, 7), record.id);
    try std.testing.expectEqual(@as(u64, 2), record.ts_ms);
    try std.testing.expectEqual(Action.delete, record.action);
    try std.testing.expectEqualStrings("x-1", record.resource.text());
}
