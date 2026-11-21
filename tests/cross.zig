//! Compile-only fixture for the cross-target catalog: everything that needs an
//! operating system (tasks, queues, files, standard streams).
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;

const Copy = struct { writer: *std.Io.Writer };

fn double(value: u32) u32 {
    return value *% 2;
}
fn add(sum: u64, value: u32) u64 {
    return sum +% value;
}
fn length(line: zrx.Line(256)) u32 {
    return @intCast(line.len);
}

export fn zrx_cross_tasks(io: *const std.Io, first: u32, end: u32) bool {
    const totals = program(zrx.merge(.{ zrx.range(u32, first, end), zrx.range(u32, first, end) }), pipe(.{
        zrx.queue(8),
        zrx.map(double),
        zrx.branch(.{
            pipe(.{ zrx.queue(2), zrx.fold(0, add), zrx.print(zrx.Stdout, "{d}\n") }),
            pipe(.{ zrx.take(1), zrx.print(zrx.Stderr, "{d}\n") }),
        }),
    })).provide(.{ zrx.stdout(64), zrx.stderr(64) });
    if (!ran(zrx.system(.{ totals, totals }), .{io.*})) return false;
    return true;
}

export fn zrx_cross_files(io: *const std.Io, from: [*:0]const u8, to: [*:0]const u8) bool {
    const copy = program(zrx.fileLines(std.mem.span(from), 256), pipe(.{
        zrx.print(Copy, "{f}\n"),
    })).provide(.{zrx.fileWriter(Copy, std.mem.span(to), 256, .{})});
    const measure = program(zrx.stdinLines(256), pipe(.{ zrx.map(length), zrx.drain() }));
    if (!ran(copy, .{io.*})) return false;
    if (!ran(measure, .{io.*})) return false;
    return true;
}

export fn zrx_cross_json(writer: *std.Io.Writer, first: u32, end: u32) bool {
    const numbers = program(zrx.range(u32, first, end), .{
        zrx.map(zrx.ext.json.encode(.{})),
        zrx.write(*std.Io.Writer, "{f}\n"),
    });
    if (!ran(numbers, .{writer})) return false;
    return true;
}

fn bytesOf(path: []const u8) zrx.FileBytes(256) {
    return zrx.fileBytes(path, 256);
}
fn count(total: u64, piece: []const u8) u64 {
    return total +% piece.len;
}
fn unread(failed: zrx.Failed(anyerror, []const u8)) zrx.Tagged([]const u8, u64) {
    return .{ .source = failed.item, .item = 0 };
}

export fn zrx_cross_file_bytes(io: *const std.Io, path: [*:0]const u8) bool {
    const sized = pipe(.{zrx.each(bytesOf, .{zrx.fold(@as(u64, 0), count)})});
    const sizes = program(zrx.fromValue(@as([]const u8, std.mem.span(path))), pipe(.{
        zrx.attempt(sized, anyerror, .{zrx.map(unread)}),
        zrx.drain(),
    }));
    if (!ran(sizes, .{io.*})) return false;
    return true;
}

export fn zrx_cross_time(io: *const std.Io) bool {
    const time = zrx.ext.time;
    const beat = program(time.ticks(.fromSeconds(1)), pipe(.{
        zrx.queue(1),
        time.throttle(.fromSeconds(5)),
        zrx.map(time.stamp(.real)),
        zrx.take(1),
        zrx.drain(),
    }));
    if (!ran(beat, .{io.*})) return false;
    return true;
}

export fn zrx_cross_timing(io: *const std.Io, first: u32, end: u32) bool {
    const batches = program(zrx.range(u32, first, end), pipe(.{
        zrx.batchWithin(1000, .fromSeconds(60)),
        zrx.flatten(),
        zrx.drain(),
    }));
    const latest = program(zrx.range(u32, first, end), pipe(.{
        zrx.debounce(.fromMilliseconds(250)),
        zrx.drain(),
    }));
    if (!ran(zrx.system(.{ batches, latest }), .{io.*})) return false;
    return true;
}

export fn zrx_cross_concurrent(io: *const std.Io, first: u32, end: u32) bool {
    const app = program(zrx.range(u32, first, end), .{
        zrx.concurrent(4, .{ zrx.map(double), zrx.fold(@as(u64, 0), add) }),
        zrx.drain(),
    });
    if (!ran(app, .{io.*})) return false;
    return true;
}

fn stopAware(stop: zrx.Stop, io: std.Io, out: anytype) !void {
    if (try out.push(1) == .more) try stop.wait(io);
}

export fn zrx_cross_completion(io: *const std.Io) bool {
    const left = pipe(.{ zrx.queue(1), zrx.take(1), zrx.drain() });
    const right = pipe(.{ zrx.take(1), zrx.drain() });
    const work = program(zrx.fromProducer(u32, stopAware), pipe(.{zrx.branch(.{ left, right })}));
    if (!ran(work, .{io.*})) return false;
    return true;
}

/// The manual clock forwards every entry of `std.Io.VTable`, whose types
/// differ per target.
export fn zrx_cross_clock(io: *const std.Io, first: u32, end: u32) bool {
    var clock: zrx.testing.Clock = .init(io.*);
    clock.advanceTo(.fromSeconds(1));
    const batches = program(zrx.range(u32, first, end), pipe(.{
        zrx.batchWithin(1000, .fromSeconds(60)),
        zrx.flatten(),
        zrx.drain(),
    }));
    if (!ran(batches, .{clock.io()})) return false;
    clock.waitingAt(.fromSeconds(61)) catch return false;
    return true;
}

const item_path = zrx.ext.pattern.seq(.{ "/items/", zrx.ext.pattern.extract(.id, zrx.ext.pattern.int(u32)) });

fn itemId(item: anytype) u32 {
    return item.found.id;
}

fn requestMethod(request: zrx.ext.http.Request) zrx.ext.http.Method {
    return request.method();
}

/// Whether a run failed, for `ran`.
const Outcome = struct { failed: *bool };

fn noteFailure(outcome: Outcome, _: anyerror) void {
    outcome.failed.* = true;
}

/// Runs `runnable` and says whether it came to its end without a failure.
fn ran(runnable: anytype, deps: anytype) bool {
    var failed = false;
    runnable.run(deps ++ .{ Outcome{ .failed = &failed }, zrx.rescue(noteFailure) });
    return !failed;
}

fn unwelcome(_: zrx.ext.http.Connection) bool {
    return false;
}

export fn zrx_cross_http(io: *const std.Io, port: u16) bool {
    const http = zrx.ext.http;
    const api = pipe(.{
        zrx.recover(anyerror, .{http.fail()}),
        zrx.route(.{
            zrx.when(http.path("/method"), .{ zrx.map(requestMethod), http.text("{t}") }),
            zrx.when(http.path(item_path), .{ zrx.map(itemId), http.text("{d}") }),
            zrx.when(zrx.all(.{ http.path("/json"), http.method(.GET) }), .{ zrx.map(zrx.constant(@as(u32, 1))), http.json() }),
            zrx.otherwise(.{http.status(.not_found)}),
        }),
    });
    const server = program(http.connections(), .{
        zrx.concurrent(2, .{zrx.route(.{
            zrx.when(unwelcome, .{http.reject()}),
            zrx.otherwise(.{ zrx.recover(http.Disconnected, .{zrx.drain()}), http.serve(api) }),
        })}),
    }).provide(.{http.listen(.{ .ip4 = .loopback(port) }, .{})});
    if (!ran(server, .{io.*})) return false;
    return true;
}
