//! Bounded import data, not CSV: three comma-separated ASCII fields, no quoting.
const std = @import("std");

pub const max_line_bytes = 256;
pub const max_records = 10_000;

/// Up to `capacity` bytes stored inline, so a value owns its text.
pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn fromSlice(text: []const u8) error{TooLong}!@This() {
            if (text.len > capacity) return error.TooLong;
            var result: @This() = .{ .len = text.len };
            @memcpy(result.bytes[0..text.len], text);
            return result;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const Identifier = Text(32);
pub const Name = Text(80);
pub const AmountText = Text(32);

pub const ValidationError = error{
    MalformedFields,
    InvalidIdentifier,
    InvalidName,
    InvalidAmount,
};

/// Policy a caller may tighten; injected into the handlers that apply it.
pub const Rules = struct {
    max_amount_cents: u32 = 1_000_000_000,
    max_records: u32 = max_records,
};

pub const Record = struct {
    identifier: Identifier,
    name: Name,
    amount_text: AmountText,
    amount_cents: u32 = 0,

    /// The normalized output line, without its newline.
    pub fn format(record: Record, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s},{s},{d}", .{ record.identifier.slice(), record.name.slice(), record.amount_cents });
    }
};

/// What is said about a rejected record: its position and the first rule it
/// broke, never its possibly sensitive content.
pub const Rejection = struct {
    number: u32,
    reason: ValidationError,

    pub fn format(rejection: Rejection, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("record {d}: {s}", .{ rejection.number, @errorName(rejection.reason) });
    }
};

/// A rejection is explicit domain data, never a fabricated valid record.
pub const Outcome = union(enum) {
    record: Record,
    rejected: ValidationError,

    pub fn accept(record: Record) Outcome {
        return .{ .record = record };
    }

    pub fn reject(reason: ValidationError) Outcome {
        return .{ .rejected = reason };
    }
};

pub const Numbered = struct {
    number: u32 = 0,
    outcome: Outcome = .{ .rejected = error.MalformedFields },

    /// Counts every record, rejected ones included.
    pub fn advance(previous: Numbered, outcome: Outcome) Numbered {
        return .{ .number = previous.number + 1, .outcome = outcome };
    }

    pub fn isAccepted(self: Numbered) bool {
        return self.outcome == .record;
    }

    pub fn isRejected(self: Numbered) bool {
        return self.outcome == .rejected;
    }

    /// Only for an accepted value.
    pub fn record(self: Numbered) Record {
        return self.outcome.record;
    }

    /// Only for a rejected value.
    pub fn rejection(self: Numbered) Rejection {
        return .{ .number = self.number, .reason = self.outcome.rejected };
    }

    pub fn withinLimit(rules: Rules, self: Numbered) error{TooManyRecords}!Numbered {
        if (self.number > rules.max_records) return error.TooManyRecords;
        return self;
    }
};

test "numbered values count both accepted and rejected outcomes" {
    const first = Numbered.advance(.{}, .reject(error.InvalidAmount));
    try std.testing.expectEqual(@as(u32, 1), first.number);
    try std.testing.expect(first.isRejected());
    try std.testing.expectEqual(Rejection{ .number = 1, .reason = error.InvalidAmount }, first.rejection());
    const second = first.advance(.accept(.{
        .identifier = try .fromSlice("A"),
        .name = try .fromSlice("Ada"),
        .amount_text = try .fromSlice("1"),
        .amount_cents = 1,
    }));
    try std.testing.expectEqual(@as(u32, 2), second.number);
    try std.testing.expect(second.isAccepted());
}

test "the record limit is a rule" {
    const third: Numbered = .{ .number = 3 };
    _ = try Numbered.withinLimit(.{ .max_records = 3 }, third);
    try std.testing.expectError(error.TooManyRecords, Numbered.withinLimit(.{ .max_records = 2 }, third));
}

test "records and rejections format as their output lines" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}|{f}", .{
        Record{ .identifier = try .fromSlice("A"), .name = try .fromSlice("Ada"), .amount_text = try .fromSlice("042"), .amount_cents = 42 },
        Rejection{ .number = 2, .reason = error.InvalidName },
    });
    try std.testing.expectEqualStrings("A,Ada,42|record 2: InvalidName", writer.buffered());
}
