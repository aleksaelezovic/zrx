//! Fixed coordinator checkpoints, not per-item tracing or CPU-time accounting.
//! Confined to one run's coordinator; snapshot only after that run returns.
const std = @import("std");
const Phase = @import("api").Phase;
const Self = @This();

pub const Sample = struct {
    elapsed_ns: u64,
    preparation_ns: u64,
    acquisition_init_ns: u64,
    active_ns: u64,
    return_cleanup_ns: u64,
};

io: std.Io,
start: std.Io.Timestamp,
stamps: [3]?u64 = @splat(null),
invalid: bool = false,

pub fn init(io: std.Io) Self {
    return .{ .io = io, .start = std.Io.Clock.awake.now(io) };
}
fn now(self: *const Self) u64 {
    const ns = self.start.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds();
    return std.math.cast(u64, ns) orelse @panic("phase clock moved backwards or overflowed");
}
pub fn mark(self: *Self, comptime phase: Phase) void {
    const index = @backingInt(phase);
    if (self.stamps[index] != null) self.invalid = true;
    self.stamps[index] = self.now();
}

/// Incomplete failure traces remain available in stamps, but cannot masquerade
/// as successful phase samples. No zero-length phase is fabricated.
pub fn finish(self: *const Self) error{ IncompletePhaseTrace, InvalidPhaseTrace }!Sample {
    const elapsed = self.now();
    if (self.invalid) return error.InvalidPhaseTrace;
    const prepared = self.stamps[0] orelse return error.IncompletePhaseTrace;
    const ready = self.stamps[1] orelse return error.IncompletePhaseTrace;
    const observed = self.stamps[2] orelse return error.IncompletePhaseTrace;
    if (prepared > ready or ready > observed or observed > elapsed)
        return error.InvalidPhaseTrace;
    return .{
        .elapsed_ns = elapsed,
        .preparation_ns = prepared,
        .acquisition_init_ns = ready - prepared,
        .active_ns = observed - ready,
        .return_cleanup_ns = elapsed - observed,
    };
}
