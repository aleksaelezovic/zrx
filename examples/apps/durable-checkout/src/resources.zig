//! Run-scoped invocation, conditional SQLite ownership and nominal byte writers.
//! All graph requirements acquire before activation, so the immutable Command
//! must gate database acquisition, not just the eventual action callback.
const std = @import("std");
const zrx = @import("zrx");
const domain = @import("domain.zig");
const resource = zrx.resource;
const deriveResource = zrx.deriveResource;

pub const ConsoleOutput = struct { writer: *zrx.Writer };
pub const DiagnosticOutput = struct { writer: *zrx.Writer };
/// Non-checkout commands genuinely own no database connection.
pub const CheckoutStorage = struct { store: ?domain.Store };

fn acquireCommand(args: *zrx.Arguments, _: void) domain.Command {
    const values = args.values;
    return domain.Command.fromArgs(if (values.len == 0) &.{} else values[1..]) catch .invalid;
}

pub fn command() @TypeOf(resource({}, acquireCommand, null)) {
    return resource({}, acquireCommand, null);
}

fn acquireCheckoutStorage(allocator: std.mem.Allocator, selected: domain.Command, _: void) !CheckoutStorage {
    if (selected != .checkout) return .{ .store = null };
    // SQLite copies the filename during open; this conversion needs no second
    // run-scoped resource and does not outlive the managed argument storage.
    const path = try allocator.dupeSentinel(u8, selected.checkout.path, 0);
    defer allocator.free(path);
    return .{ .store = try domain.Store.open(.{ .path = path, .fault = selected.checkout.fault }) };
}

fn releaseCheckoutStorage(value: CheckoutStorage) void {
    if (value.store) |store| store.close();
}

pub fn checkoutStorage() @TypeOf(resource({}, acquireCheckoutStorage, releaseCheckoutStorage)) {
    return resource({}, acquireCheckoutStorage, releaseCheckoutStorage);
}

pub fn consoleOutput() @TypeOf(deriveResource(ConsoleOutput, zrx.writer(.stdout))) {
    return deriveResource(ConsoleOutput, zrx.writer(.stdout));
}

pub fn diagnosticOutput() @TypeOf(deriveResource(DiagnosticOutput, zrx.writer(.stderr))) {
    return deriveResource(DiagnosticOutput, zrx.writer(.stderr));
}
