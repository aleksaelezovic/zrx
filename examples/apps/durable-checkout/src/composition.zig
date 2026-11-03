//! One visible command flow. Domain transformations are pure; SQLite issuance
//! stays one transactional storage operation, never per-statement pipe effects.
const zrx = @import("zrx");
const domain = @import("domain.zig");
const resources = @import("resources.zig");
const pipe = zrx.pipe;
const fromService = zrx.fromService;
const branch = zrx.branch;
const when = zrx.when;
const otherwise = zrx.otherwise;
const map = zrx.map;
const forEach = zrx.forEach;
const writeLine = zrx.writeLine;

fn writeHelp(output: resources.ConsoleOutput, _: domain.Command) !void {
    try output.writer.write(domain.usage);
    try output.writer.flush();
}

fn writeInvalidUsage(output: resources.DiagnosticOutput, _: domain.Command) !void {
    try output.writer.write("error: InvalidArguments\n" ++ domain.usage);
    try output.writer.flush();
    return error.InvalidArguments;
}

fn issue(service: resources.CheckoutStorage, request: domain.Request) domain.StoreError!domain.Result {
    // The same immutable Command both selects this branch and acquires storage.
    return service.store.?.issue(request);
}

fn writeReceipt(output: resources.ConsoleOutput, selected: domain.Command, text: domain.Text) !void {
    if (selected.checkout.fault == .output) return error.OutputUnavailable;
    try writeLine(output.writer, text);
}

/// Each case completes itself. There is no shared completion value, exit-status
/// cell, child run, or action performed merely to select a command.
pub const commandFlow = pipe(fromService(domain.Command), .{branch(.{
    when(domain.Command.isHelp, forEach(writeHelp)),
    when(domain.Command.isInvalid, forEach(writeInvalidUsage)),
    otherwise(.{
        map(domain.Command.checkoutRequest),
        map(issue),
        map(domain.Result.toText),
        forEach(writeReceipt),
    }),
})});
