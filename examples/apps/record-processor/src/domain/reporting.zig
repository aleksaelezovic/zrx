//! Per-record output and the contribution emitted after successful delivery.
const std = @import("std");
const records = @import("records.zig");
const summaries = @import("summary.zig");

pub const Report = struct {
    destination: enum { accepted, diagnostic },
    text: records.Text,
    contribution: summaries.Summary,

    pub fn fromNumbered(value: records.Numbered) Report {
        if (value.isRejected()) {
            return .{
                .destination = .diagnostic,
                .text = records.Text.fromFormat("record {d}: {s}", .{
                    value.number, @errorName(value.outcome.rejected),
                }) catch unreachable,
                .contribution = .{ .rejected = 1 },
            };
        }
        const record = value.outcome.record;
        return .{
            .destination = .accepted,
            .text = records.Text.fromFormat("{s},{s},{d}", .{
                record.identifier.bytes[0..record.identifier.len],
                record.name.bytes[0..record.name.len],
                record.amount_cents,
            }) catch unreachable, // 32 + 80 + 10 + delimiters < 256
            .contribution = .{ .accepted = 1, .amount_cents = record.amount_cents },
        };
    }

    pub fn summary(self: Report) summaries.Summary {
        return self.contribution;
    }
};

test "record reports select destinations and contribute only their own outcome" {
    const accepted = Report.fromNumbered(.{ .number = 1, .outcome = .{ .record = .{
        .identifier = try records.Identifier.fromSlice("A"),
        .name = try records.Name.fromSlice("Ada"),
        .amount_text = try records.AmountText.fromSlice("42"),
        .amount_cents = 42,
    } } });
    try std.testing.expect(accepted.destination == .accepted);
    try std.testing.expectEqualStrings("A,Ada,42", accepted.text.bytes[0..accepted.text.len]);
    try std.testing.expectEqualDeep(summaries.Summary{ .accepted = 1, .amount_cents = 42 }, accepted.summary());
    const rejected = Report.fromNumbered(.{ .number = 2, .outcome = .{ .rejected = error.InvalidAmount } });
    try std.testing.expect(rejected.destination == .diagnostic);
    try std.testing.expectEqualStrings("record 2: InvalidAmount", rejected.text.bytes[0..rejected.text.len]);
    try std.testing.expectEqualDeep(summaries.Summary{ .rejected = 1 }, rejected.summary());
}
