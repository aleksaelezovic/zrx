const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const map = zrx.map;
const recover = zrx.recover;
const branch = zrx.branch;
const whenError = zrx.whenError;
const otherwise = zrx.otherwise;
const forEach = zrx.forEach;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

const E = error{ Bad, Other };
fn parse(value: u32) E!u32 {
    return switch (value) {
        0 => error.Bad,
        1 => error.Other,
        else => value,
    };
}
fn widen(value: u32) u64 {
    return value * 10;
}
fn fallback(_: error{Bad}) u64 {
    return 42;
}
fn fallbackAll(_: anyerror) u64 {
    return 99;
}
const Output = struct { items: std.ArrayList(u64) = .empty };
fn save(output: *Output, value: u64) !void {
    try output.items.append(allocator, value);
}
fn report(failure: zrx.Failure(error{Bad})) u64 {
    return if (failure.err == error.Bad) 42 else unreachable;
}
fn reportAll(_: zrx.Failure(anyerror)) u64 {
    return 99;
}

test "pending errors skip success stages across type transitions and recover narrowly" {
    var output: Output = .{};
    defer output.items.deinit(allocator);
    try run(.{ allocator, io, &output }, .{pipe(zrx.fromSlice(&[_]u32{ 0, 1, 2 }), .{
        map(parse), map(widen), recover(fallback), recover(fallbackAll), forEach(save),
    })});
    try std.testing.expectEqualSlices(u64, &.{ 42, 99, 20 }, output.items.items);
}

test "unhandled errors fail at terminal and otherwise is success only" {
    try std.testing.expectError(error.Other, run(.{ allocator, io }, .{
        pipe(zrx.fromValue(@as(u32, 1)), .{ map(parse), branch(.{
            whenError(error{Bad}, zrx.discard()), otherwise(zrx.discard()),
        }) }),
    }));
}

test "error cases are persistent typed lanes and first matching set wins" {
    var output: Output = .{};
    defer output.items.deinit(allocator);
    const routed = pipe(zrx.fromSlice(&[_]u32{ 0, 1, 2 }), .{ map(parse), branch(.{
        whenError(error{Bad}, map(report)),
        whenError(anyerror, map(reportAll)),
        otherwise(map(widen)),
    }) });
    try run(.{ allocator, io, &output }, .{pipe(&routed, .{forEach(save)})});
    std.mem.sort(u64, output.items.items, {}, std.sort.asc(u64));
    try std.testing.expectEqualSlices(u64, &.{ 20, 42, 99 }, output.items.items);
}

test "unmatched value branch errors bypass ordinary cases to downstream recovery" {
    var output: Output = .{};
    defer output.items.deinit(allocator);
    const routed = pipe(zrx.fromValue(@as(u32, 0)), .{ map(parse), branch(.{otherwise(map(widen))}) });
    try run(.{ allocator, io, &output }, .{pipe(&routed, .{ recover(fallback), forEach(save) })});
    try std.testing.expectEqualSlices(u64, &.{42}, output.items.items);
}

test "shared operation outcome is evaluated once and each edge handles it" {
    const Probe = struct { calls: usize = 0 };
    const Helpers = struct {
        fn fail(probe: *Probe, _: u32) E!u64 {
            probe.calls += 1;
            return error.Bad;
        }
    };
    var probe: Probe = .{};
    const source = pipe(zrx.fromValue(@as(u32, 0)), .{map(Helpers.fail)});
    try run(.{ allocator, io, &probe }, .{
        pipe(&source, .{ recover(fallback), zrx.discard() }),
        pipe(&source, .{branch(.{ whenError(anyerror, zrx.discard()), otherwise(zrx.discard()) })}),
    });
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "cancellation and source failures never reach operation handlers" {
    const Helpers = struct {
        fn canceled(_: u32) error{Canceled}!u64 {
            return error.Canceled;
        }
        fn source(_: *zrx.Emitter(u64)) error{SourceFailed}!void {
            return error.SourceFailed;
        }
        fn forbidden(_: anyerror) u64 {
            @panic("control error reached recovery");
        }
    };
    try std.testing.expectError(error.Canceled, run(.{ allocator, io }, .{
        pipe(zrx.fromValue(@as(u32, 0)), .{ map(Helpers.canceled), recover(Helpers.forbidden), zrx.discard() }),
    }));
    try std.testing.expectError(error.SourceFailed, run(.{ allocator, io }, .{
        pipe(zrx.Stream(u64).fromProducer(1, Helpers.source), .{ recover(Helpers.forbidden), zrx.discard() }),
    }));
}

test "tap and filter failures skip later success effects and can recover" {
    const Helpers = struct {
        fn effect(_: u32) E!void {
            return error.Bad;
        }
        fn predicate(_: u32) E!bool {
            return error.Bad;
        }
        fn forbidden(_: u32) u64 {
            @panic("success callback ran with a pending error");
        }
    };
    inline for (.{ zrx.tap(Helpers.effect), zrx.filter(Helpers.predicate) }) |operation| {
        var output: Output = .{};
        defer output.items.deinit(allocator);
        try run(.{ allocator, io, &output }, .{pipe(zrx.fromValue(@as(u32, 0)), .{
            operation, map(Helpers.forbidden), recover(fallback), forEach(save),
        })});
        try std.testing.expectEqualSlices(u64, &.{42}, output.items.items);
    }
}

test "retired error lane does not swallow a queued or later error" {
    const Helpers = struct {
        fn reportOne(failure: zrx.Failure(E)) u64 {
            return if (failure.err == error.Bad) 42 else 99;
        }
    };
    try std.testing.expectError(error.Bad, run(.{ allocator, io }, .{
        pipe(zrx.fromSlice(&[_]u32{ 0, 0, 2 }), .{ map(parse), branch(.{
            whenError(E, .{ map(Helpers.reportOne), zrx.take(1), zrx.discard() }),
            otherwise(zrx.discard()),
        }) }),
    }));
}

test "reporting failure is a new unhandled operation error not recursively routed" {
    const Helpers = struct {
        fn report(_: zrx.Failure(anyerror)) error{ReportFailed}!u64 {
            return error.ReportFailed;
        }
    };
    try std.testing.expectError(error.ReportFailed, run(.{ allocator, io }, .{
        pipe(zrx.fromValue(@as(u32, 0)), .{ map(parse), branch(.{
            whenError(anyerror, .{ map(Helpers.report), zrx.discard() }),
            otherwise(zrx.discard()),
        }) }),
    }));
}

test "recover dependencies use normal DI and suffix errors never request a binding" {
    const Service = struct { value: u64 };
    const Helpers = struct {
        fn replace(service: Service, _: error{Bad}) u64 {
            return service.value;
        }
    };
    var output: Output = .{};
    defer output.items.deinit(allocator);
    try run(.{ allocator, io, &output, Service{ .value = 7 }, @as(error{Bad}, error.Bad) }, .{
        pipe(zrx.fromValue(@as(u32, 0)), .{ map(parse), map(widen), recover(Helpers.replace), forEach(save) }),
    });
    try std.testing.expectEqualSlices(u64, &.{7}, output.items.items);
}

test "prefix counts successes and suffix suppresses retained values on operation failure" {
    const input = zrx.fromSlice(&[_]u32{ 0, 2, 3 });
    var output: Output = .{};
    defer output.items.deinit(allocator);
    try run(.{ allocator, io, &output }, .{
        pipe(input, .{ map(parse), map(widen), zrx.take(1), recover(fallback), forEach(save) }),
    });
    try std.testing.expectEqualSlices(u64, &.{ 42, 20 }, output.items.items);
    output.items.clearRetainingCapacity();
    try run(.{ allocator, io, &output }, .{
        pipe(input, .{ map(parse), map(widen), zrx.takeLast(2), recover(fallback), forEach(save) }),
    });
    try std.testing.expectEqualSlices(u64, &.{42}, output.items.items);
}

test "sampling skips pending errors without reading signal state as a handler" {
    const Pair = @Tuple(&.{ u32, u64 });
    const Helpers = struct {
        fn replacement(_: E) Pair {
            return .{ 42, 99 };
        }
        fn check(value: Pair) !void {
            try std.testing.expectEqual(@as(u32, 42), value[0]);
        }
    };
    const state = pipe(zrx.fromSlice(&[_]u64{}), .{zrx.hold(@as(u64, 5))});
    try run(.{ allocator, io }, .{
        pipe(zrx.fromValue(@as(u32, 0)), .{ map(parse), zrx.withLatestFrom(&state), recover(Helpers.replacement), forEach(Helpers.check) }),
    });
}

test "unhandled operation failures discard partial terminal batches" {
    const Probe = struct { calls: usize = 0 };
    const Helpers = struct {
        fn batch(probe: *Probe, _: []const u32) void {
            probe.calls += 1;
        }
    };
    var probe: Probe = .{};
    try std.testing.expectError(error.Bad, run(.{ allocator, io, &probe }, .{
        pipe(zrx.fromSlice(&[_]u32{ 2, 3, 4, 0 }), .{ map(parse), zrx.batchThen(2, Helpers.batch) }),
    }));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "fallible error sink fails normally and releases its managed reporting resource" {
    const Probe = struct { acquired: usize = 0, released: usize = 0, reports: usize = 0 };
    const Reporter = struct { probe: *Probe };
    const Helpers = struct {
        fn acquire(probe: *Probe, _: void) Reporter {
            probe.acquired += 1;
            return .{ .probe = probe };
        }
        fn release(reporter: Reporter) void {
            reporter.probe.released += 1;
        }
        fn report(reporter: Reporter, failure: zrx.Failure(E)) error{ReportFailed}!void {
            std.debug.assert(failure._receipt == null);
            std.debug.assert(reporter.probe.released == 0);
            reporter.probe.reports += 1;
            return error.ReportFailed;
        }
    };
    var probe: Probe = .{};
    try std.testing.expectError(error.ReportFailed, run(.{
        allocator, io, &probe, zrx.resource({}, Helpers.acquire, Helpers.release),
    }, .{
        pipe(zrx.fromValue(@as(u32, 0)), .{ map(parse), branch(.{
            whenError(E, forEach(Helpers.report)), otherwise(zrx.discard()),
        }) }),
    }));
    try std.testing.expectEqual(@as(usize, 1), probe.acquired);
    try std.testing.expectEqual(@as(usize, 1), probe.released);
    try std.testing.expectEqual(@as(usize, 1), probe.reports);
}

test "retry exhaustion uses error lanes and incoming pending errors bypass attempts" {
    const Probe = struct { attempts: usize = 0, policies: usize = 0 };
    const Helpers = struct {
        fn fail(probe: *Probe, _: u32) E!u64 {
            probe.attempts += 1;
            return error.Bad;
        }
        fn policy(probe: *Probe, _: E, _: usize) zrx.RetryDecision {
            probe.policies += 1;
            return .stop;
        }
    };
    var probe: Probe = .{};
    const retried = zrx.retryPipe(zrx.fromValue(@as(u32, 0)), .{map(Helpers.fail)}, Helpers.policy);
    try run(.{ allocator, io, &probe }, .{
        pipe(&retried, .{branch(.{ whenError(E, zrx.discard()), otherwise(zrx.discard()) })}),
    });
    try std.testing.expectEqual(@as(usize, 1), probe.attempts);
    try std.testing.expectEqual(@as(usize, 1), probe.policies);
    probe = .{};
    const failed = pipe(zrx.fromValue(@as(u32, 0)), .{map(parse)});
    const skipped = zrx.retryPipe(failed, .{map(Helpers.fail)}, Helpers.policy);
    try run(.{ allocator, io, &probe }, .{pipe(skipped, .{ recover(fallback), zrx.discard() })});
    try std.testing.expectEqual(@as(usize, 0), probe.attempts);
    try std.testing.expectEqual(@as(usize, 0), probe.policies);
}

test "persistent error lane batches accept reports without per error singleton execution" {
    const Reports = struct { calls: usize = 0, count: usize = 0 };
    const Helpers = struct {
        fn batch(reports: *Reports, items: []const zrx.Failure(E)) void {
            reports.calls += 1;
            reports.count += items.len;
            for (items) |item| std.debug.assert(item._receipt == null);
        }
    };
    var reports: Reports = .{};
    try run(.{ allocator, io, &reports }, .{
        pipe(zrx.fromSlice(&[_]u32{ 0, 1, 0, 2 }), .{ map(parse), branch(.{
            whenError(E, zrx.batchThen(2, Helpers.batch)), otherwise(zrx.discard()),
        }) }),
    });
    try std.testing.expectEqual(@as(usize, 2), reports.calls);
    try std.testing.expectEqual(@as(usize, 3), reports.count);
}

test "fold discards partial state and scan skips failed updates" {
    const Helpers = struct {
        fn add(state: u64, value: u32) u64 {
            return state + value;
        }
    };
    const input = zrx.fromSlice(&[_]u32{ 2, 0, 3 });
    var folded: Output = .{};
    defer folded.items.deinit(allocator);
    try run(.{ allocator, io, &folded }, .{
        pipe(input, .{ map(parse), zrx.fold(@as(u64, 0), Helpers.add), recover(fallback), forEach(save) }),
    });
    try std.testing.expectEqualSlices(u64, &.{42}, folded.items.items);
    var scanned: Output = .{};
    defer scanned.items.deinit(allocator);
    try run(.{ allocator, io, &scanned }, .{
        pipe(input, .{ map(parse), zrx.scan(@as(u64, 0), Helpers.add), recover(fallback), forEach(save) }),
    });
    try std.testing.expectEqualSlices(u64, &.{ 2, 42, 5 }, scanned.items.items);
}

test "merge forwards pending errors to recovery rather than promoting to source failure" {
    const failed = pipe(zrx.fromValue(@as(u32, 0)), .{ map(parse), map(widen) });
    const success = zrx.fromValue(@as(u64, 20));
    var output: Output = .{};
    defer output.items.deinit(allocator);
    try run(.{ allocator, io, &output }, .{
        pipe(zrx.merge(.{ &failed, &success }), .{ recover(fallback), forEach(save) }),
    });
    std.mem.sort(u64, output.items.items, {}, std.sort.asc(u64));
    try std.testing.expectEqualSlices(u64, &.{ 20, 42 }, output.items.items);
}

fn allocationFixture(gpa: std.mem.Allocator) !void {
    try run(.{ gpa, io }, .{
        pipe(zrx.fromSlice(&[_]u32{ 0, 1, 2 }), .{ map(parse), branch(.{
            whenError(E, map(struct {
                fn report(_: zrx.Failure(E)) u32 {
                    return 42;
                }
            }.report)),
            otherwise(map(struct {
                fn same(value: u32) u32 {
                    return value;
                }
            }.same)),
        }), zrx.discard() }),
    });
}
test "every preparation allocation failure unwinds mixed outcome branches" {
    try std.testing.checkAllAllocationFailures(allocator, allocationFixture, .{});
}

test "actual error example swaps sinks while keeping named domain stages" {
    const example = @import("errors_example");
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const success = try std.fs.path.join(allocator, &.{ root, "success" });
    defer allocator.free(success);
    const errors = try std.fs.path.join(allocator, &.{ root, "errors" });
    defer allocator.free(errors);
    try run(.{ allocator, io }, .{example.program(
        zrx.fromSlice(&[_]u32{ 2, 0, 1, 3 }),
        zrx.writeFileLines(success, .{ .exclusive = true }),
        zrx.writeFileLines(errors, .{ .exclusive = true }),
    )});
    const output = try temp.dir.readFileAlloc(io, "success", allocator, .limited(1024));
    defer allocator.free(output);
    const reports = try temp.dir.readFileAlloc(io, "errors", allocator, .limited(1024));
    defer allocator.free(reports);
    try std.testing.expectEqualStrings("result: 4\nresult: 6\n", output);
    try std.testing.expectEqualStrings("error: Invalid\nerror: Unavailable\n", reports);
}
