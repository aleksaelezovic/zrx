//! Test-only access to live transport and error-lane lifecycle state.
//! No declaration operators or alternative executor are exposed here.
const transport = @import("internal/runtime/streams.zig");
pub const Stream = transport.Stream;
pub const tee = transport.tee;
pub const stopProducer = transport.stopProducer;
pub const ErrorReceipt = @import("internal/error_receipt.zig").Receipt;
pub const acceptFailure = @import("internal/error_receipt.zig").accept;
pub const Failure = @import("data/failures.zig").Failure;
pub const ErrorRouter = @import("internal/runtime/branch.zig").Router;
