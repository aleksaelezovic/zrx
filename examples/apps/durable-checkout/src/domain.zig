//! Public checkout interface. Consumers import this file; domain implementations
//! import their specific siblings rather than depending on this facade.
pub const Request = @import("domain/request.zig").Request;
pub const Result = @import("domain/result.zig").Result;
pub const Command = @import("domain/commands.zig").Command;
pub const Store = @import("domain/store.zig").Store;

pub const Checkout = @import("domain/commands.zig").Checkout;
pub const StoreConfig = @import("domain/store.zig").Config;
pub const StoreError = @import("domain/store.zig").Error;
pub const Text = @import("domain/result.zig").Text;
pub const Fault = @import("domain/fault.zig").Fault;
pub const usage = @import("domain/commands.zig").usage;
