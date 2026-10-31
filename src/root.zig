//! Public zrx API. Implementations and contracts live beside their named entry points.
//! See docs/README.md for guides and executable examples.

pub const pipe = @import("pipe.zig").pipe;
pub const tryPipe = @import("tryPipe.zig").tryPipe;
pub const run = @import("run.zig").run;

pub const Stream = @import("data/streams.zig").Stream;
pub const Emitter = @import("data/streams.zig").Emitter;
pub const fromIterator = @import("data/iterators.zig").fromIterator;
pub const readFrom = @import("io/readFrom.zig").readFrom;
pub const Line = @import("data/lines.zig").Line;
pub const line = @import("data/lines.zig").line;
pub const stdinLines = @import("io/lines.zig").stdinLines;
pub const fileLines = @import("io/lines.zig").fileLines;
pub const tcpLines = @import("io/lines.zig").tcpLines;
pub const stdoutLines = @import("io/lines.zig").stdoutLines;
pub const stderrLines = @import("io/lines.zig").stderrLines;
pub const writeFileLines = @import("io/lines.zig").writeFileLines;

pub const map = @import("ops/map.zig").map;
pub const keepIf = @import("ops/keepIf.zig").keepIf;
pub const each = @import("ops/each.zig").each;
pub const filter = @import("ops/filter.zig").filter;
pub const fold = @import("ops/fold.zig").fold;
pub const tryFold = @import("ops/tryFold.zig").tryFold;
pub const scan = @import("ops/scan.zig").scan;
pub const tap = @import("ops/tap.zig").tap;
pub const tapWith = @import("ops/tapWith.zig").tapWith;
pub const maxItems = @import("ops/maxItems.zig").maxItems;
pub const take = @import("ops/take.zig").take;
pub const takeLast = @import("ops/takeLast.zig").takeLast;
pub const merge = @import("ops/merge.zig").merge;
pub const hold = @import("ops/hold.zig").hold;
pub const values = @import("ops/values.zig").values;
pub const withLatestFrom = @import("ops/withLatestFrom.zig").withLatestFrom;
pub const forEach = @import("ops/forEach.zig").forEach;
pub const forEachWith = @import("ops/forEachWith.zig").forEachWith;
pub const collectThen = @import("ops/collectThen.zig").collectThen;
pub const collectThenWith = @import("ops/collectThenWith.zig").collectThenWith;
pub const batchThen = @import("ops/batchThen.zig").batchThen;
pub const batchThenWith = @import("ops/batchThenWith.zig").batchThenWith;
