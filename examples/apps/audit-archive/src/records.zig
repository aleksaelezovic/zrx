const std = @import("std");

pub const max_line = 1024;
pub const scratch_bytes = 8 * 1024;
const Action = enum { read, create, update, delete };

const JsonUnsigned = struct {
    value: u64,

    pub fn jsonParse(_: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !JsonUnsigned {
        const value = switch (try source.next()) {
            .number => |bytes| std.fmt.parseInt(u64, bytes, 10) catch return error.InvalidNumber,
            else => return error.UnexpectedToken,
        };
        return .{ .value = value };
    }
};

const JsonString = struct {
    bytes: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !JsonString {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        return .{ .bytes = try std.json.innerParse([]const u8, allocator, source, options) };
    }
};

const Input = struct {
    id: JsonUnsigned,
    ts_ms: JsonUnsigned,
    action: JsonString,
    resource: JsonString,
    actor: JsonString,
    detail: ?JsonString = null,
};

/// Only these fields are queued and archived. The identifier owns its bytes.
pub const Record = struct {
    id: u64,
    ts_ms: u64,
    action: Action,
    resource_len: u8,
    resource: [96]u8,

    pub fn write(self: Record, writer: *std.Io.Writer) !void {
        try std.json.Stringify.value(.{
            .id = self.id,
            .ts_ms = self.ts_ms,
            .action = self.action,
            .resource = self.resource[0..self.resource_len],
        }, .{}, writer);
        try writer.writeByte('\n');
    }
};

pub fn redact(line: []const u8) error{InvalidRecord}!Record {
    var scratch: [scratch_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const raw = std.json.parseFromSliceLeaky(Input, fixed.allocator(), line, .{}) catch
        return error.InvalidRecord;
    const resource = raw.resource.bytes;
    const action = std.meta.stringToEnum(Action, raw.action.bytes) orelse return error.InvalidRecord;
    if (raw.actor.bytes.len == 0 or resource.len == 0 or resource.len > 96)
        return error.InvalidRecord;
    for (resource) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.')
            return error.InvalidRecord;
    }
    var record: Record = .{
        .id = raw.id.value,
        .ts_ms = raw.ts_ms.value,
        .action = action,
        .resource_len = @intCast(resource.len),
        .resource = @splat(0),
    };
    @memcpy(record.resource[0..resource.len], resource);
    return record;
}

test "redaction copies decoded fields and writes a fixed allowlist" {
    const input =
        \\{"id":1,"ts_ms":2,"action":"read","resource":"port\u002d7","actor":"private","detail":"secret"}
    ;
    var line = input.*;
    const record = try redact(&line);
    @memset(&line, 'x');
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try record.write(&writer);
    try std.testing.expectEqualStrings("{\"id\":1,\"ts_ms\":2,\"action\":\"read\",\"resource\":\"port-7\"}\n", writer.buffered());
}

test "unknown, duplicate and unsafe fields fail validation" {
    for ([_][]const u8{
        \\{"id":1,"ts_ms":2,"action":"read","resource":"x","actor":"a","extra":true}
        ,
        \\{"id":1,"id":2,"ts_ms":2,"action":"read","resource":"x","actor":"a"}
        ,
        \\{"id":1,"ts_ms":2,"action":"read","resource":"x\ny","actor":"a"}
        ,
        \\{"id":"1","ts_ms":2,"action":"read","resource":"x","actor":"a"}
        ,
        \\{"id":1,"ts_ms":2,"action":"read","resource":[120],"actor":"a"}
        ,
    }) |input| {
        try std.testing.expectError(error.InvalidRecord, redact(input));
    }
}
