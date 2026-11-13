//! zrx: declarative push streams with type-keyed dependency injection.
//!
//! A *program* is one source feeding one pipe; a *pipe* is a composition of
//! operators that ends in a terminal one; operators take *handlers*, plain
//! functions whose leading parameters are injected by type. Everything is
//! resolved at compile time.
//!
//!     const total = pipe(.{ map(scale), filter(isLarge), fold(@as(u64, 0), add), subscribe(report) });
//!     try program(fromSlice(&values), total).run(.{Scale{ .by = 2 }});

// Composition
pub const pipe = @import("pipe.zig").pipe;
pub const program = @import("program.zig").program;

// Sources
const sources = @import("sources.zig");
pub const fromSlice = sources.fromSlice;
pub const fromValue = sources.fromValue;
pub const range = sources.range;
pub const fromIterator = sources.fromIterator;
pub const fromProducer = sources.fromProducer;

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

// Terminal operators
const sink = @import("ops/sink.zig");
pub const subscribe = sink.subscribe;
pub const drain = sink.drain;

// The dependency operator
pub const provide = @import("ops/env.zig").provide;

// For writing operators, sources and handlers of your own.
pub const Flow = @import("pipe.zig").Flow;
pub const End = @import("pipe.zig").End;
pub const di = @import("di.zig");
pub const operator = @import("pipe.zig");
