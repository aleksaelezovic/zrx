//! Bounded import data, not CSV: three comma-separated ASCII fields, no quoting.

const std = @import("std");
const zrx = @import("zrx");

pub const max_line_bytes = 256;
pub const max_records = 10_000;

// The domain uses bounded value types, not zrx execution or I/O APIs.
pub const Text = zrx.Line(max_line_bytes);
pub const Identifier = zrx.Line(32);
pub const Name = zrx.Line(80);
pub const AmountText = zrx.Line(32);

pub const ValidationError = error{
    MalformedFields,
    InvalidIdentifier,
    InvalidName,
    InvalidAmount,
};

pub const Rules = struct {
    max_amount_cents: u32 = 1_000_000_000,
};

pub const Record = struct {
    identifier: Identifier,
    name: Name,
    amount_text: AmountText,
    amount_cents: u32 = 0,
};

// A rejection is explicit domain data, never a fabricated valid record.
pub const Outcome = union(enum) {
    record: Record,
    rejected: ValidationError,

    pub fn fromRecord(record: Record) Outcome {
        return .{ .record = record };
    }
};

pub const Numbered = struct {
    number: u32 = 0,
    outcome: Outcome = .{ .rejected = error.MalformedFields },

    // Pure recurrence after recovery: count every record, including rejections.
    pub fn advance(previous: Numbered, outcome: Outcome) Numbered {
        return .{ .number = previous.number + 1, .outcome = outcome };
    }

    pub fn isRejected(self: Numbered) bool {
        return self.outcome == .rejected;
    }
};

test "numbered values count both accepted and rejected outcomes" {
    const first = Numbered.advance(.{}, .{ .rejected = error.InvalidAmount });
    try std.testing.expectEqual(@as(u32, 1), first.number);
    try std.testing.expect(first.isRejected());
    const second = first.advance(.{ .record = .{
        .identifier = try Identifier.fromSlice("A"),
        .name = try Name.fromSlice("Ada"),
        .amount_text = try AmountText.fromSlice("1"),
        .amount_cents = 1,
    } });
    try std.testing.expectEqual(@as(u32, 2), second.number);
    try std.testing.expect(!second.isRejected());
}
