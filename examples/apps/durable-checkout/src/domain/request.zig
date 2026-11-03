//! Identity is the exact (cart, numeric cents) pair; the key names one issuance.
//! Identifiers are case-sensitive ASCII tokens, with no trimming/normalization.
const std = @import("std");

pub const Request = struct {
    key: []const u8,
    cart: []const u8,
    cents: u32,

    pub fn validate(self: Request) error{InvalidRequest}!void {
        if (!validToken(self.key) or !validToken(self.cart) or self.cents == 0)
            return error.InvalidRequest;
    }
};

fn validToken(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
}
