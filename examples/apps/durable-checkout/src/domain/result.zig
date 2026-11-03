const Request = @import("request.zig").Request;
pub const Text = @import("zrx").Line(256);

/// A local receipt, not evidence of a payment or shipment.
/// Request referents remain borrowed from the caller through run.
pub const Result = struct {
    checkout_id: i64,
    request: Request,
    reused: bool,

    /// Owned output with no LF. Valid receipts need fewer than 128 bytes:
    /// at most 64 cart bytes, 19 ID digits, 10 amount digits and fixed framing.
    pub fn toText(self: Result) Text {
        return Text.fromFormat("{s} checkout={d} cart={s} cents={d}", .{
            if (self.reused) "reused" else "issued",
            self.checkout_id,
            self.request.cart,
            self.request.cents,
        }) catch unreachable;
    }
};
