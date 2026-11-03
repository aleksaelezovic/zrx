//! Production declarations shared by the CLI and integration tests.
const zrx = @import("zrx");
const records = @import("domain/records.zig");
const validation = @import("domain/validation.zig");
const reporting = @import("domain/reporting.zig");
const resources = @import("resources.zig");
const commands = @import("domain/commands.zig");
const Summary = @import("domain/summary.zig").Summary;
const pipe = zrx.pipe;
const map = zrx.map;
const recover = zrx.recover;
const scan = zrx.scan;
const fold = zrx.fold;
const branch = zrx.branch;
const when = zrx.when;
const otherwise = zrx.otherwise;
const tap = zrx.tap;
const maxItems = zrx.maxItems;
const forEach = zrx.forEach;
const fromService = zrx.fromService;
const readChunks = zrx.readChunks;
const splitBy = zrx.splitBy;
const writeLine = zrx.writeLine;
const flatMap = zrx.flatMap;

fn writeReport(accepted: resources.AcceptedOutput, diagnostic: resources.DiagnosticOutput, report: reporting.Report) !void {
    const writer = switch (report.destination) {
        .accepted => accepted.writer.?,
        .diagnostic => diagnostic.writer,
    };
    try writeLine(writer, report.text);
}

fn recordText(chunk: zrx.Chunk(u8, records.max_line_bytes)) records.Text {
    return records.Text.fromSlice(chunk.slice()) catch unreachable;
}

const InputRecords = @TypeOf(pipe(readChunks(4096, @as(*zrx.Reader, undefined)), .{
    splitBy('\n', .{ .max_items = records.max_line_bytes }),
    map(recordText),
}));

fn readInput(input: resources.Input) InputRecords {
    return pipe(readChunks(4096, input.reader), .{
        splitBy('\n', .{ .max_items = records.max_line_bytes }),
        map(recordText),
    });
}

fn writeHelp(output: resources.ConsoleOutput, _: commands.Command) !void {
    try output.writer.write(commands.usage);
    try output.writer.flush();
}

/// Usage is delivered before the expected command error reaches the caller.
fn writeInvalidUsage(output: resources.DiagnosticOutput, _: commands.Command) !void {
    try output.writer.write("fatal: InvalidArguments\n" ++ commands.usage);
    try output.writer.flush();
    return error.InvalidArguments;
}

/// All record effects finished before this terminal. A failed summary write
/// takes precedence over the expected rejected-record outcome.
fn writeSummary(output: resources.ConsoleOutput, value: Summary) !void {
    try writeLine(output.writer, value.toText());
    if (value.rejected != 0) return error.RejectedRecords;
}

// One cold synchronous child, instantiated only for a selected process command.
// The fold belongs to that child: selected empty input emits a zero summary;
// an unselected command constructs no child and therefore emits no summary.
const processRecords = pipe(fromService(resources.Input), .{
    flatMap(readInput),
    maxItems(records.max_records),
    map(.{
        validation.parseFields,
        validation.validateIdentifier,
        validation.normalizeName,
        validation.validateAmount,
    }),
    map(records.Outcome.fromRecord),
    // Only schema errors become rejections; source/control failures stay fatal.
    recover(validation.reject),
    scan(records.Numbered{}, records.Numbered.advance),
    map(reporting.Report.fromNumbered),
    tap(writeReport),
    // Publish totals only after successful report delivery.
    map(reporting.Report.summary),
    fold(Summary{}, Summary.add),
});

fn process(_: commands.Command) @TypeOf(processRecords) {
    return processRecords;
}

/// One selected pipeline, with independent terminal command cases. Construction
/// performs no I/O; flatMap creates fresh child traversal/state when selected.
pub const commandFlow = pipe(fromService(commands.Command), .{branch(.{
    when(commands.Command.isHelp, forEach(writeHelp)),
    when(commands.Command.isInvalid, forEach(writeInvalidUsage)),
    otherwise(.{ flatMap(process), forEach(writeSummary) }),
})});
