//! Parsing and normalization handlers for the import schema. Each stage takes
//! and returns an ordinary `Record`; the first failure names the broken rule.
const std = @import("std");
const records = @import("records.zig");
const Record = records.Record;
const ValidationError = records.ValidationError;
const Rules = records.Rules;

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t");
}

pub fn parseFields(line: []const u8) ValidationError!Record {
    // Accept CRLF, but never embed CR in output.
    const bytes = if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line;
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
    for (record.name.slice()) |byte| {
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
    const bytes = record.amount_text.slice();
    if (bytes.len == 0) return error.InvalidAmount;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidAmount;
    record.amount_cents = std.fmt.parseInt(u32, bytes, 10) catch return error.InvalidAmount;
    if (record.amount_cents > rules.max_amount_cents) return error.InvalidAmount;
    return record;
}

test "named validation stages and injected amount policy" {
    const parsed = try parseFields(" ab-1 , Ada  Lovelace , 00042\r");
    const valid = try validateAmount(.{}, try normalizeName(try validateIdentifier(parsed)));
    try std.testing.expectEqualStrings("AB-1", valid.identifier.slice());
    try std.testing.expectEqualStrings("Ada Lovelace", valid.name.slice());
    try std.testing.expectEqual(@as(u32, 42), valid.amount_cents);
    try std.testing.expectError(error.InvalidAmount, validateAmount(.{ .max_amount_cents = 41 }, valid));
}

test "schema rejects invalid fields without accepting a numeric prefix" {
    try std.testing.expectError(error.MalformedFields, parseFields("a,b,1,extra"));
    try std.testing.expectError(error.MalformedFields, parseFields(""));
    try std.testing.expectError(error.InvalidIdentifier, validateIdentifier(try parseFields("?,Ada,1")));
    try std.testing.expectError(error.InvalidName, normalizeName(try parseFields("a,A\tB,1")));
    inline for (.{ "", "-1", "+1", "1.2", "12x", "1000000001", "999999999999999999999" }) |amount| {
        try std.testing.expectError(error.InvalidAmount, validateAmount(.{}, try parseFields("a,Ada," ++ amount)));
    }
}
