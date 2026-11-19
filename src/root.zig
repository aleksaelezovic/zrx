//! zrx: declarative push streams with type-keyed dependency injection.
//!
//! A *program* is one source feeding one pipe; a *pipe* is a composition of
//! operators that ends in a terminal one; operators take *handlers*, plain
//! functions whose leading parameters are injected by type. A *system* runs
//! several programs together. Everything is resolved at compile time.
//!
//!     const total = pipe(.{ map(scale), filter(isLarge), fold(@as(u64, 0), add), forEach(report) });
//!     try program(fromSlice(&values), total).run(.{ io, Scale{ .by = 2 } });

// Composition
pub const pipe = @import("pipe.zig").pipe;
pub const program = @import("program.zig").program;
pub const system = @import("program.zig").system;

// Sources
const sources = @import("sources.zig");
pub const fromSlice = sources.fromSlice;
pub const fromValue = sources.fromValue;
pub const range = sources.range;
pub const fromIterator = sources.fromIterator;
pub const fromProducer = sources.fromProducer;
pub const merge = sources.merge;
pub const mergeTagged = sources.mergeTagged;
pub const Tagged = sources.Tagged;
pub const Stop = @import("completion.zig").Stop;

// Per-item operators
const transform = @import("ops/transform.zig");
pub const map = transform.map;
pub const filter = transform.filter;
pub const tap = transform.tap;
pub const scan = transform.scan;
pub const fold = transform.fold;
pub const take = transform.take;
pub const skip = transform.skip;
pub const takeWhile = transform.takeWhile;
pub const flatten = transform.flatten;
pub const batch = transform.batch;
pub const Batch = transform.Batch;
pub const recover = transform.recover;

// Terminal operators
const sink = @import("ops/sink.zig");
pub const forEach = sink.forEach;
pub const drain = sink.drain;

// Program resources
pub const resource = @import("resources.zig").resource;

// Flow operators
const flow = @import("ops/flow.zig");
pub const queue = flow.queue;
pub const branch = flow.branch;
pub const route = flow.route;
pub const when = flow.when;
pub const otherwise = flow.otherwise;
pub const concurrent = @import("ops/concurrent.zig").concurrent;

const timing = @import("ops/timing.zig");
pub const batchWithin = timing.batchWithin;
pub const debounce = timing.debounce;

// Handler combinators
const handlers = @import("handlers.zig");
pub const not = handlers.not;
pub const all = handlers.all;
pub const any = handlers.any;
pub const compose = handlers.compose;
pub const orElse = handlers.orElse;
pub const require = handlers.require;
pub const reduce = handlers.reduce;
pub const field = handlers.field;
pub const constant = handlers.constant;
pub const eq = handlers.eq;
pub const ne = handlers.ne;
pub const lt = handlers.lt;
pub const le = handlers.le;
pub const gt = handlers.gt;
pub const ge = handlers.ge;

// I/O
const io = @import("io.zig");
pub const Stdout = io.Stdout;
pub const Stderr = io.Stderr;
pub const stdout = io.stdout;
pub const stderr = io.stderr;
pub const fileWriter = io.fileWriter;
pub const FileMode = io.FileMode;
pub const FileWriterOptions = io.FileWriterOptions;
pub const print = io.print;
pub const write = io.write;
pub const Line = io.Line;
pub const lines = io.lines;
pub const stdinLines = io.stdinLines;
pub const fileLines = io.fileLines;

/// Modules built on the contracts below. Each is compiled only when used.
pub const ext = struct {
    pub const json = @import("ext/json.zig");
};

// For writing operators, sources and handlers of your own.
pub const Flow = @import("pipe.zig").Flow;
pub const End = @import("pipe.zig").End;
pub const di = @import("di.zig");
pub const operator = @import("pipe.zig");
