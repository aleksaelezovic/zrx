//! Upstream demand for a run whose producer can be woken by early completion.
const std = @import("std");
const Io = std.Io;

/// A producer dependency that reports when downstream needs no more input.
/// Its lifetime is the producer's call. Caller cancellation is still an error.
/// It waits on the `io` it is given, which is the producer's `std.Io`: so a
/// deadline the producer read is on the clock it waits on.
pub const Stop = struct {
    signal: ?*Signal = null,

    pub fn requested(stop: Stop) bool {
        return if (stop.signal) |signal| signal.event.isSet() else false;
    }

    pub fn wait(stop: Stop, io: Io) Io.Cancelable!void {
        if (stop.signal) |signal| return signal.event.wait(io);
        var event: Io.Event = .unset;
        return event.wait(io);
    }

    /// `wait` with an end: `error.Timeout` once `timeout` is over, and for
    /// a wake that is neither, as `std.Io.Event.waitTimeout` reports one.
    pub fn waitTimeout(stop: Stop, io: Io, timeout: Io.Timeout) Io.Event.WaitTimeoutError!void {
        if (stop.signal) |signal| return signal.event.waitTimeout(io, timeout);
        var event: Io.Event = .unset;
        return event.waitTimeout(io, timeout);
    }
};

/// Set through `io`, the `std.Io` its producer is given and waits on: an
/// event is woken only through the backend it is waited on.
pub const Signal = struct {
    io: Io,
    event: Io.Event = .unset,
};

/// Internal environment marker. Only a pipe feeding this signal tracks demand.
pub const Track = struct {};

pub fn sourceWantsStop(comptime Source: type) bool {
    return @hasDecl(Source, "zrx_stop_source") and Source.zrx_stop_source;
}

/// One segment or sub-pipe. The caller links the tree before any task starts.
pub const Demand = struct {
    parent: ?*Demand = null,
    signal: ?*Signal = null,
    consumers: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(bool) = .init(false),

    pub fn addConsumer(demand: *Demand, child: *Demand) void {
        demand.consumers.raw += 1;
        child.* = .{ .parent = demand };
    }

    pub fn complete(demand: *Demand) void {
        var node = demand;
        while (!node.completed.swap(true, .monotonic)) {
            if (node.signal) |signal| signal.event.set(signal.io);
            const parent = node.parent orelse return;
            if (parent.consumers.fetchSub(1, .monotonic) != 1) return;
            node = parent;
        }
    }
};

/// Assigns one caller-owned demand node to each boundary as its task is built.
pub const Collector = struct {
    owner: *Demand,
    nodes: *[]Demand,

    pub fn addSegment(collector: *Collector) *Demand {
        const child = &collector.nodes.*[0];
        collector.nodes.* = collector.nodes.*[1..];
        collector.owner.addConsumer(child);
        collector.owner = child;
        return child;
    }
};
