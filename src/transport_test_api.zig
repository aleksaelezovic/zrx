//! Test-only access to live transport for deterministic join/retirement schedules.
//! No declaration operators or alternative executor are exposed here.
const transport = @import("internal/runtime/streams.zig");
pub const Stream = transport.Stream;
pub const tee = transport.tee;
pub const stopProducer = transport.stopProducer;
