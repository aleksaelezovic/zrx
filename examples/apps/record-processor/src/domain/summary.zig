//! Processing totals and their final textual representation.
const std = @import("std");
const records = @import("records.zig");

pub const Summary = struct {
    accepted: u32 = 0,
    rejected: u32 = 0,
    amount_cents: u64 = 0,

    pub fn add(self: Summary, delta: Summary) Summary {
        return .{
            .accepted = self.accepted + delta.accepted,
            .rejected = self.rejected + delta.rejected,
            .amount_cents = self.amount_cents + delta.amount_cents,
        };
    }

    pub fn toText(self: Summary) records.Text {
        // Even the largest representable counts/total fit Text's bound.
        return records.Text.fromFormat("summary: accepted={d} rejected={d} amount_cents={d}", .{
            self.accepted, self.rejected, self.amount_cents,
        }) catch unreachable;
    }
};

test "summary value methods add totals and produce bounded text" {
    const combined = (Summary{ .accepted = 1, .amount_cents = 42 }).add(.{ .rejected = 1 });
    try std.testing.expectEqualDeep(Summary{ .accepted = 1, .rejected = 1, .amount_cents = 42 }, combined);
    const text = combined.toText();
    try std.testing.expectEqualStrings("summary: accepted=1 rejected=1 amount_cents=42", text.bytes[0..text.len]);
}
