//! Private access to coordinator checkpoints for opt-in measurements.
pub const zrx = @import("root.zig");
pub const Phase = @import("internal/execution/observation.zig").Phase;
pub const Noop = @import("internal/execution/observation.zig").Noop;
pub const runObserved = @import("run.zig").runObserved;
