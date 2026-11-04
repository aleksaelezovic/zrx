const std = @import("std");

pub const max_values = 16;
pub const Submission = struct { label: []const u8, values: []const i32 };

/// Owns all input bytes/values; nothing from a request or JSON arena escapes.
pub const Job = struct {
    label: [32]u8 = @splat(0),
    label_len: usize,
    values: [max_values]i32 = @splat(0),
    values_len: usize,
    result: i64,

    pub fn labelText(self: *const Job) []const u8 {
        return self.label[0..self.label_len];
    }
};

pub fn validate(limit: usize, input: Submission) error{InvalidJob}!Job {
    if (input.label.len == 0 or input.label.len > 32 or
        input.values.len == 0 or input.values.len > limit or
        input.values.len > max_values) return error.InvalidJob;
    for (input.label) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidJob;
    }
    var job: Job = .{ .label_len = input.label.len, .values_len = input.values.len, .result = 0 };
    @memcpy(job.label[0..input.label.len], input.label);
    for (input.values, 0..) |value, i| {
        if (value < -1_000_000 or value > 1_000_000) return error.InvalidJob;
        job.values[i] = value;
        job.result += value;
    }
    return job;
}

pub const Record = struct { id: u64, job: Job };

/// Strict JSON types, exactly the two named fields, no duplicate/unknown fields.
/// Parsing storage is request-local; only the validated owned Job survives.
pub fn decode(allocator: std.mem.Allocator, limit: usize, body: []const u8) error{ InvalidJob, OutOfMemory }!Job {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
        .max_value_len = 4096,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJob,
    };
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 2) return error.InvalidJob;
    const label = parsed.value.object.get("label") orelse return error.InvalidJob;
    const values = parsed.value.object.get("values") orelse return error.InvalidJob;
    if (label != .string or values != .array or values.array.items.len > max_values) return error.InvalidJob;
    var numbers: [max_values]i32 = undefined;
    for (values.array.items, 0..) |value, i| {
        if (value != .integer) return error.InvalidJob;
        numbers[i] = std.math.cast(i32, value.integer) orelse return error.InvalidJob;
    }
    return validate(limit, .{ .label = label.string, .values = numbers[0..values.array.items.len] });
}
