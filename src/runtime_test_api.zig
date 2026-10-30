// Internal cursor/transport test facade, including test-only eager consumers.
// None of its ownership/collection helpers are exported from the public API.
const core = @import("root.zig");
const runtime = @import("internal/runtime/streams.zig");
const visits = @import("internal/test_consumers.zig");
pub const pipe = core.pipe;
pub const tryPipe = core.tryPipe;
pub const map = core.map;
pub const keepIf = core.keepIf;
pub const each = core.each;
pub const filter = core.filter;
pub const collectInto = visits.collectInto;
pub const collectAlloc = visits.collectAlloc;
pub const fromIterator = core.fromIterator;
pub const forEach = visits.forEach;
pub const forEachWith = visits.forEachWith;
pub const Stream = runtime.Stream;
pub const tee = runtime.tee;
pub const share = runtime.share;
pub const readFrom = core.readFrom;
