//! One private module owns shared files for the legacy/current comparison.
//! This is not an exported package or public compatibility mode.
pub const legacy = @import("legacy_test_api.zig");
pub const current = @import("root.zig");
pub const Phase = @import("internal/execution/observation.zig").Phase;
pub const Noop = @import("internal/execution/observation.zig").Noop;
pub const runObserved = @import("run.zig").runObserved;
pub const legacyRunObserved = @import("internal/graph_run.zig").runObserved;
