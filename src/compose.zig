const std = @import("std");
const decl = @import("data/declarations.zig");
const composition = @import("internal/composition.zig");
const effects = @import("ops/effects.zig");

/// Connect declarations. No transformations, effects, acquisitions, or iteration
/// run here. Scalars must be declared with fromValue; slices with fromSlice.
pub fn pipe(source: anytype, operators: anytype) composition.PipelineOutput(@TypeOf(source), @TypeOf(operators)) {
    decl.requireSource(@TypeOf(source));
    return composition.compose(source, operators, 0);
}

pub fn map(comptime transforms: anytype) @TypeOf(decl.transform(.map, transforms)) {
    return decl.transform(.map, transforms);
}
pub const each = map;
pub fn filter(comptime predicates: anytype) @TypeOf(decl.transform(.filter, predicates)) {
    return decl.transform(.filter, predicates);
}
pub fn tap(comptime effects_tuple: anytype) @TypeOf(decl.transform(.tap, effects_tuple)) {
    return decl.transform(.tap, effects_tuple);
}
pub fn forEach(comptime effect: anytype) @TypeOf(effects.terminal(.each, 0, effect)) {
    return effects.terminal(.each, 0, effect);
}
pub fn collectThen(comptime effect: anytype) @TypeOf(effects.terminal(.collect, 0, effect)) {
    return effects.terminal(.collect, 0, effect);
}
pub fn batchThen(size: usize, comptime effect: anytype) @TypeOf(effects.terminal(.batch, size, effect)) {
    return effects.terminal(.batch, size, effect);
}
pub fn fromIterator(iterator: anytype) @TypeOf(decl.borrowed(@import("data/iterators.zig").fromIterator(iterator))) {
    return decl.borrowed(@import("data/iterators.zig").fromIterator(iterator));
}
pub fn readFrom(queue: anytype) @TypeOf(@import("io/readFrom.zig").readFrom(queue)) {
    return @import("io/readFrom.zig").readFrom(queue);
}
pub fn stdoutLines() @TypeOf(effects.external(@import("io/lines.zig").stdoutLines())) {
    return effects.external(@import("io/lines.zig").stdoutLines());
}
pub fn stderrLines() @TypeOf(effects.external(@import("io/lines.zig").stderrLines())) {
    return effects.external(@import("io/lines.zig").stderrLines());
}
pub fn respondHttp() @TypeOf(effects.external(@import("io/http.zig").respondHttp())) {
    return effects.external(@import("io/http.zig").respondHttp());
}
pub fn writeFileLines(path: []const u8, options: std.Io.Dir.CreateFileOptions) @TypeOf(effects.external(@import("io/lines.zig").writeFileLines(path, options))) {
    return effects.external(@import("io/lines.zig").writeFileLines(path, options));
}
