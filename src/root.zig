//! Public zrx API. Implementations and contracts live beside their named entry points.
//! See docs/README.md for guides and executable examples.

pub const pipe = @import("compose.zig").pipe;
pub const run = @import("run.zig").run;

pub const resource = @import("internal/world/resources.zig").resource;
pub const deriveResource = @import("internal/world/resources.zig").deriveResource;
pub const fromSlice = @import("data/declarations.zig").fromSlice;
pub const fromValue = @import("data/declarations.zig").fromValue;
pub const Stream = @import("data/declarations.zig").Stream;
pub const Emitter = @import("data/streams.zig").Emitter;
pub const fromIterator = @import("compose.zig").fromIterator;
pub const readFrom = @import("compose.zig").readFrom;
pub const Line = @import("data/lines.zig").Line;
pub const line = @import("data/lines.zig").line;
pub const stdinLines = @import("io/lines.zig").stdinLines;
pub const fileLines = @import("io/lines.zig").fileLines;
pub const tcpLines = @import("io/lines.zig").tcpLines;
pub const stdoutLines = @import("compose.zig").stdoutLines;
pub const stderrLines = @import("compose.zig").stderrLines;
pub const writeFileLines = @import("compose.zig").writeFileLines;

pub const map = @import("compose.zig").map;
pub const each = @import("compose.zig").each;
pub const filter = @import("compose.zig").filter;
pub const fold = @import("data/declarations.zig").fold;
pub const scan = @import("ops/scan.zig").scan;
pub const tap = @import("compose.zig").tap;
pub const maxItems = @import("ops/maxItems.zig").maxItems;
pub const take = @import("ops/take.zig").take;
pub const takeLast = @import("ops/takeLast.zig").takeLast;
pub const merge = @import("ops/merge.zig").merge;
pub const hold = @import("ops/hold.zig").hold;
pub const values = @import("ops/values.zig").values;
pub const withLatestFrom = @import("ops/withLatestFrom.zig").withLatestFrom;
pub const forEach = @import("compose.zig").forEach;
pub const collectThen = @import("compose.zig").collectThen;
pub const batchThen = @import("compose.zig").batchThen;
