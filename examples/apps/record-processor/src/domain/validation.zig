//! Parsing and normalization handlers for the import schema.
const std = @import("std");
const records = @import("records.zig");
const Text = records.Text;
const Record = records.Record;
const Outcome = records.Outcome;
const ValidationError = records.ValidationError;
const Rules = records.Rules;

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t");
}

pub fn parseFields(input: Text) ValidationError!Record {
    var bytes = input.bytes[0..input.len];
    // Accept CRLF, but never embed CR in output.
    if (std.mem.endsWith(u8, bytes, "\r")) bytes = bytes[0 .. bytes.len - 1];
    var fields = std.mem.splitScalar(u8, bytes, ',');
    const identifier = trim(fields.next().?);
    const name = trim(fields.next() orelse return error.MalformedFields);
    const amount = trim(fields.next() orelse return error.MalformedFields);
    if (fields.next() != null) return error.MalformedFields;
    return .{
        .identifier = records.Identifier.fromSlice(identifier) catch return error.InvalidIdentifier,
        .name = records.Name.fromSlice(name) catch return error.InvalidName,
        .amount_text = records.AmountText.fromSlice(amount) catch return error.InvalidAmount,
    };
}

pub fn validateIdentifier(value: Record) ValidationError!Record {
    var record = value;
    if (record.identifier.len == 0) return error.InvalidIdentifier;
    for (record.identifier.bytes[0..record.identifier.len]) |*byte| {
        if (!std.ascii.isAlphanumeric(byte.*) and byte.* != '-' and byte.* != '_')
            return error.InvalidIdentifier;
        byte.* = std.ascii.toUpper(byte.*);
    }
    return record;
}

pub fn normalizeName(value: Record) ValidationError!Record {
    var record = value;
    if (record.name.len == 0) return error.InvalidName;
    var normalized: records.Name = .{};
    for (record.name.bytes[0..record.name.len]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != ' ' and byte != '\'' and byte != '-' and byte != '.')
            return error.InvalidName;
        if (byte == ' ' and normalized.len > 0 and normalized.bytes[normalized.len - 1] == ' ')
            continue;
        normalized.bytes[normalized.len] = byte;
        normalized.len += 1;
    }
    record.name = normalized;
    return record;
}

pub fn validateAmount(rules: Rules, value: Record) ValidationError!Record {
    var record = value;
    const bytes = record.amount_text.bytes[0..record.amount_text.len];
    if (bytes.len == 0) return error.InvalidAmount;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidAmount;
    record.amount_cents = std.fmt.parseInt(u32, bytes, 10) catch return error.InvalidAmount;
    if (record.amount_cents > rules.max_amount_cents) return error.InvalidAmount;
    return record;
}

pub fn reject(err: ValidationError) Outcome {
    return .{ .rejected = err };
}

test "named validation stages and injected amount policy" {
    const parsed = try parseFields(try Text.fromSlice(" ab-1 , Ada  Lovelace , 00042\r"));
    const valid = try validateAmount(.{}, try normalizeName(try validateIdentifier(parsed)));
    try std.testing.expectEqualStrings("AB-1", valid.identifier.bytes[0..valid.identifier.len]);
    try std.testing.expectEqualStrings("Ada Lovelace", valid.name.bytes[0..valid.name.len]);
    try std.testing.expectEqual(@as(u32, 42), valid.amount_cents);
    try std.testing.expectError(error.InvalidAmount, validateAmount(.{ .max_amount_cents = 41 }, valid));
}

test "schema rejects invalid fields without accepting a numeric prefix" {
    try std.testing.expectError(error.MalformedFields, parseFields(try Text.fromSlice("a,b,1,extra")));
    try std.testing.expectError(error.InvalidIdentifier, validateIdentifier(try parseFields(try Text.fromSlice("?,Ada,1"))));
    try std.testing.expectError(error.InvalidName, normalizeName(try parseFields(try Text.fromSlice("a,A\tB,1"))));
    inline for (.{ "", "-1", "+1", "1.2", "12x", "1000000001", "999999999999999999999" }) |amount| {
        try std.testing.expectError(error.InvalidAmount, validateAmount(.{}, try parseFields(try Text.fromSlice("a,Ada," ++ amount))));
    }
}
