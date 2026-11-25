//! Processing totals.
const std = @import("std");
const records = @import("records.zig");

pub const Summary = struct {
    accepted: u32 = 0,
    rejected: u32 = 0,
    amount_cents: u64 = 0,

    /// What one record contributes.
    pub fn of(numbered: records.Numbered) Summary {
        return switch (numbered.outcome) {
            .record => |record| .{ .accepted = 1, .amount_cents = record.amount_cents },
            .rejected => .{ .rejected = 1 },
        };
    }

    pub fn add(self: Summary, delta: Summary) Summary {
        return .{
            .accepted = self.accepted + delta.accepted,
            .rejected = self.rejected + delta.rejected,
            .amount_cents = self.amount_cents + delta.amount_cents,
        };
    }

    pub fn format(self: Summary, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("summary: accepted={d} rejected={d} amount_cents={d}", .{ self.accepted, self.rejected, self.amount_cents });
    }
};

test "summaries add up and format as the final line" {
    const accepted = Summary.of(.{ .number = 1, .outcome = .accept(.{
        .identifier = try .fromSlice("A"),
        .name = try .fromSlice("Ada"),
        .amount_text = try .fromSlice("42"),
        .amount_cents = 42,
    }) });
    const combined = accepted.add(Summary.of(.{ .number = 2, .outcome = .reject(error.InvalidAmount) }));
    try std.testing.expectEqual(Summary{ .accepted = 1, .rejected = 1, .amount_cents = 42 }, combined);
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}", .{combined});
    try std.testing.expectEqualStrings("summary: accepted=1 rejected=1 amount_cents=42", writer.buffered());
}
