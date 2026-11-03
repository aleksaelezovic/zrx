const std = @import("std");
const builtin = @import("builtin");
const app = @import("checkout");
const zrx = @import("zrx");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const allocator = std.testing.allocator;
const io = std.testing.io;
const Command = app.domain.Command;
const Request = app.domain.Request;

test "identity tokens are bounded, case-sensitive ASCII with no normalization" {
    try (Request{ .key = "Cart_A-7", .cart = "cart-a", .cents = 1 }).validate();
    const too_long: [65]u8 = @splat('a');
    const longest: [64]u8 = @splat('a');
    for ([_][]const u8{ "", "has space", "line\n", "é", "slash/cart", &too_long }) |value| {
        try expectError(error.InvalidRequest, (Request{ .key = value, .cart = "cart-a", .cents = 1 }).validate());
        try expectError(error.InvalidRequest, (Request{ .key = "key-a", .cart = value, .cents = 1 }).validate());
    }
    try (Request{ .key = &longest, .cart = &longest, .cents = 1 }).validate();
    try expectError(error.InvalidRequest, (Request{ .key = "k", .cart = "c", .cents = 0 }).validate());
}

test "CLI parses numeric identity and rejects invalid or unbounded requests" {
    const parsed = (try Command.fromArgs(&.{ "checkout.db", "key-a", "cart-a", "02500" })).checkout;
    try std.testing.expectEqual(@as(u32, 2500), parsed.request.cents);
    try std.testing.expectEqual(app.domain.Fault.none, parsed.fault);
    const fault = (try Command.fromArgs(&.{ "checkout.db", "key-a", "cart-a", "1", "--fault", "after-commit" })).checkout;
    try std.testing.expectEqual(app.domain.Fault.after_commit, fault.fault);
    try expect((try Command.fromArgs(&.{"--help"})).isHelp());
    try expectError(error.InvalidArguments, Command.fromArgs(&.{}));
    try expectError(error.InvalidArguments, Command.fromArgs(&.{ "db", "k", "c", "0" }));
    try expectError(error.InvalidArguments, Command.fromArgs(&.{ "db", "k", "c", "4294967296" }));
    try expectError(error.InvalidArguments, Command.fromArgs(&.{ "db", "k", "c", "1", "--fault", "unknown" }));
    try expectError(error.InvalidArguments, Command.fromArgs(&.{ ":memory:", "k", "c", "1" }));
    try expectError(error.InvalidArguments, Command.fromArgs(&.{ "", "k", "c", "1" }));
    try expectError(error.InvalidArguments, Command.fromArgs(&.{ "db\x00other", "k", "c", "1" }));
    try expectError(error.InvalidArguments, Command.fromArgs(&.{ "--help", "extra" }));
}

test "storage refuses ephemeral or embedded-NUL paths before opening" {
    try expectError(error.InvalidDatabasePath, app.domain.Store.open(.{ .path = ":memory:" }));
    try expectError(error.InvalidDatabasePath, app.domain.Store.open(.{ .path = "" }));
    try expectError(error.InvalidDatabasePath, app.domain.Store.open(.{ .path = "file\x00other" }));
}

test "production command composition is cold" {
    // Neither declaration construction nor recipe construction acquires SQLite.
    const description = app.composition.commandFlow;
    _ = description;
    _ = app.resources.command();
    _ = app.resources.checkoutStorage();
}

test "receipt formatting produces owned text without implicit framing" {
    const receipt = app.domain.Result{
        .checkout_id = 1,
        .request = .{ .key = "key-a", .cart = "cart-a", .cents = 2500 },
        .reused = false,
    };
    const text = receipt.toText();
    try std.testing.expectEqualStrings("issued checkout=1 cart=cart-a cents=2500", text.bytes[0..text.len]);
}

test "execute propagates cold allocation failure without output" {
    const args: std.process.Args = if (builtin.os.tag == .windows)
        .{ .vector = std.unicode.utf8ToUtf16LeStringLiteral("durable-checkout --help") }
    else
        .{ .vector = &.{ "durable-checkout", "--help" } };
    var failing: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = 0 });
    try expectError(error.OutOfMemory, app.execute(failing.allocator(), io, args));
}

fn expectNoStorage(value: app.resources.CheckoutStorage) !void {
    try expect(value.store == null);
}

test "non-action commands acquire no database connection" {
    for ([_]Command{ .help, .invalid }) |command| {
        try zrx.run(.{ allocator, io, command, app.resources.checkoutStorage() }, .{
            zrx.pipe(zrx.fromService(app.resources.CheckoutStorage), .{zrx.forEach(expectNoStorage)}),
        });
    }
}

// Inject real managed byte-writer roles into the production command declaration.
// The parser receives ordinary non-sentinel slices via the borrowed argv view.
fn runWithFiles(argv: []const []const u8, stdout: []const u8, stderr: []const u8) !void {
    var args = zrx.Arguments{ .values = argv };
    return zrx.run(.{
        allocator,
        io,
        &args,
        app.resources.command(),
        app.resources.checkoutStorage(),
        zrx.deriveResource(app.resources.ConsoleOutput, zrx.writer(.{ .file = .{ .path = stdout, .options = .{} } })),
        zrx.deriveResource(app.resources.DiagnosticOutput, zrx.writer(.{ .file = .{ .path = stderr, .options = .{} } })),
    }, .{app.composition.commandFlow});
}

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(io, path, allocator, .limited(4096));
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "help and usage terminate through the production flow with injected writers" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const stdout = try std.fs.path.join(allocator, &.{ root, "stdout" });
    defer allocator.free(stdout);
    const stderr = try std.fs.path.join(allocator, &.{ root, "stderr" });
    defer allocator.free(stderr);

    try runWithFiles(&.{ "durable-checkout", "--help" }, stdout, stderr);
    try expectFile(temp.dir, "stdout", app.domain.usage);
    try expectFile(temp.dir, "stderr", "");
    try expectError(error.InvalidArguments, runWithFiles(&.{"durable-checkout"}, stdout, stderr));
    try expectFile(temp.dir, "stdout", "");
    try expectFile(temp.dir, "stderr", "error: InvalidArguments\n" ++ app.domain.usage);
}

test "checkout and conflict use the same production flow and persisted transaction" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const stdout = try std.fs.path.join(allocator, &.{ root, "stdout" });
    defer allocator.free(stdout);
    const stderr = try std.fs.path.join(allocator, &.{ root, "stderr" });
    defer allocator.free(stderr);
    const database = try std.fs.path.join(allocator, &.{ root, "checkout.db" });
    defer allocator.free(database);
    const argv = &.{ "durable-checkout", database, "key-a", "cart-a", "2500" };
    try runWithFiles(argv, stdout, stderr);
    try expectFile(temp.dir, "stdout", "issued checkout=1 cart=cart-a cents=2500\n");
    try runWithFiles(argv, stdout, stderr);
    try expectFile(temp.dir, "stdout", "reused checkout=1 cart=cart-a cents=2500\n");
    try expectError(error.Conflict, runWithFiles(&.{ "durable-checkout", database, "key-a", "other", "2500" }, stdout, stderr));
    try expectFile(temp.dir, "stdout", "");
    // Fatal diagnostics belong to main; no intermediate success is fabricated.
    try expectFile(temp.dir, "stderr", "");
    try runWithFiles(argv, stdout, stderr);
    try expectFile(temp.dir, "stdout", "reused checkout=1 cart=cart-a cents=2500\n");
}

test "help and usage propagate real standard-writer failures" {
    for ([_]Command{ .help, .invalid }) |command| {
        var output: zrx.Writer = .{ .output = .stdout };
        output.writer = .{ .io = io, .file = .stdout(), .interface = .failing };
        var diagnostic: zrx.Writer = .{ .output = .stderr };
        diagnostic.writer = .{ .io = io, .file = .stderr(), .interface = .failing };
        try expectError(error.WriteFailed, zrx.run(.{
            allocator,
            io,
            command,
            app.resources.checkoutStorage(),
            app.resources.ConsoleOutput{ .writer = &output },
            app.resources.DiagnosticOutput{ .writer = &diagnostic },
        }, .{app.composition.commandFlow}));
    }
}

test "standard-writer failure after issuance still reuses the persisted receipt" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const stdout = try std.fs.path.join(allocator, &.{ root, "stdout" });
    defer allocator.free(stdout);
    const stderr = try std.fs.path.join(allocator, &.{ root, "stderr" });
    defer allocator.free(stderr);
    const database = try std.fs.path.join(allocator, &.{ root, "checkout.db" });
    defer allocator.free(database);
    const argv = &.{ "durable-checkout", database, "key-a", "cart-a", "2500" };
    var args = zrx.Arguments{ .values = argv };
    var output: zrx.Writer = .{ .output = .stdout };
    output.writer = .{ .io = io, .file = .stdout(), .interface = .failing };
    var diagnostic: zrx.Writer = .{ .output = .stderr };
    diagnostic.writer = .{ .io = io, .file = .stderr(), .interface = .failing };
    try expectError(error.WriteFailed, zrx.run(.{
        allocator,
        io,
        &args,
        app.resources.command(),
        app.resources.checkoutStorage(),
        app.resources.ConsoleOutput{ .writer = &output },
        app.resources.DiagnosticOutput{ .writer = &diagnostic },
    }, .{app.composition.commandFlow}));
    try runWithFiles(argv, stdout, stderr);
    try expectFile(temp.dir, "stdout", "reused checkout=1 cart=cart-a cents=2500\n");
    try expectFile(temp.dir, "stderr", "");
}

// Writes fit entirely in this borrowed standard writer's buffer. Only the
// explicit flush fails; drain_calls detects any premature write failure.
const BufferedFlushFailure = struct {
    writer: zrx.Writer = .{ .output = .stdout },
    buffer: [4096]u8 = undefined,
    drain_calls: usize = 0,
    flush_calls: usize = 0,

    fn init(self: *BufferedFlushFailure) void {
        self.writer.writer = .{
            .io = io,
            .file = .stdout(),
            .interface = .{
                .buffer = &self.buffer,
                .vtable = &.{ .drain = drain, .flush = flush },
            },
        };
    }

    fn owner(interface: *std.Io.Writer) *BufferedFlushFailure {
        const file_writer: *std.Io.File.Writer = @fieldParentPtr("interface", interface);
        const byte_writer: *zrx.Writer = @fieldParentPtr("writer", file_writer);
        return @fieldParentPtr("writer", byte_writer);
    }

    fn drain(interface: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
        owner(interface).drain_calls += 1;
        return error.WriteFailed;
    }

    fn flush(interface: *std.Io.Writer) std.Io.Writer.Error!void {
        owner(interface).flush_calls += 1;
        return error.WriteFailed;
    }

    fn expectBuffered(self: *BufferedFlushFailure, expected: []const u8, flush_calls: usize) !void {
        try std.testing.expectEqualStrings(expected, self.writer.writer.interface.buffered());
        try std.testing.expectEqual(@as(usize, 0), self.drain_calls);
        try std.testing.expectEqual(flush_calls, self.flush_calls);
    }
};

test "help and usage fail when successful buffered writes cannot flush" {
    for ([_]Command{ .help, .invalid }) |command| {
        var output: BufferedFlushFailure = .{};
        output.init();
        var diagnostic: BufferedFlushFailure = .{};
        diagnostic.init();
        try expectError(error.WriteFailed, zrx.run(.{
            allocator,
            io,
            command,
            app.resources.checkoutStorage(),
            app.resources.ConsoleOutput{ .writer = &output.writer },
            app.resources.DiagnosticOutput{ .writer = &diagnostic.writer },
        }, .{app.composition.commandFlow}));
        if (command == .help) {
            try output.expectBuffered(app.domain.usage, 1);
            try diagnostic.expectBuffered("", 0);
        } else {
            // The delivery failure takes precedence over InvalidArguments.
            try output.expectBuffered("", 0);
            try diagnostic.expectBuffered("error: InvalidArguments\n" ++ app.domain.usage, 1);
        }
    }
}

test "receipt flush failure propagates without undoing the committed checkout" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const stdout = try std.fs.path.join(allocator, &.{ root, "stdout" });
    defer allocator.free(stdout);
    const stderr = try std.fs.path.join(allocator, &.{ root, "stderr" });
    defer allocator.free(stderr);
    const database = try std.fs.path.join(allocator, &.{ root, "checkout.db" });
    defer allocator.free(database);
    const argv = &.{ "durable-checkout", database, "key-a", "cart-a", "2500" };
    var args = zrx.Arguments{ .values = argv };
    var output: BufferedFlushFailure = .{};
    output.init();
    var diagnostic: BufferedFlushFailure = .{};
    diagnostic.init();
    try expectError(error.WriteFailed, zrx.run(.{
        allocator,
        io,
        &args,
        app.resources.command(),
        app.resources.checkoutStorage(),
        app.resources.ConsoleOutput{ .writer = &output.writer },
        app.resources.DiagnosticOutput{ .writer = &diagnostic.writer },
    }, .{app.composition.commandFlow}));
    try output.expectBuffered("issued checkout=1 cart=cart-a cents=2500\n", 1);
    try diagnostic.expectBuffered("", 0);
    try runWithFiles(argv, stdout, stderr);
    try expectFile(temp.dir, "stdout", "reused checkout=1 cart=cart-a cents=2500\n");
    try expectFile(temp.dir, "stderr", "");
}
