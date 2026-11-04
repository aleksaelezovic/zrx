//! Three application resources: config, store and server.
const std = @import("std");
const zrx = @import("zrx");
const commands = @import("domain/commands.zig");
const Store = @import("store.zig").Store;
const resource = zrx.resource;

pub const Server = struct { server: *zrx.HttpServer };
/// Borrowed constructor capabilities, not additional application services.
pub const ServerOptions = struct {
    ready: ?*zrx.HttpReady = null,
    stop: ?*std.Io.Event = null,
    console: std.Io.File = .stdout(),
};

fn parseConfig(allocator: std.mem.Allocator, args: std.process.Args) !commands.Config {
    // Config contains only owned scalar values. No argument slices escape.
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const values = try args.toSlice(arena.allocator());
    return commands.Config.fromArgs(if (values.len == 0) &.{} else values[1..]);
}

pub fn configuration(args: std.process.Args) @TypeOf(resource(args, parseConfig, null)) {
    return resource(args, parseConfig, null);
}

fn openStore(allocator: std.mem.Allocator, settings: commands.Config, _: void) !*Store {
    try settings.validate();
    const state = try allocator.create(Store);
    errdefer allocator.destroy(state);
    state.* = try Store.init(allocator, settings.max_jobs);
    return state;
}

fn closeStore(allocator: std.mem.Allocator, state: *Store) void {
    state.deinit(allocator);
    allocator.destroy(state);
}

pub fn store() @TypeOf(resource({}, openStore, closeStore)) {
    return resource({}, openStore, closeStore);
}

fn openServer(allocator: std.mem.Allocator, io: std.Io, settings: commands.Config, state: *Store, options: ServerOptions) !Server {
    try settings.validate();
    if (state.records.len != settings.max_jobs) return error.InvalidStoreCapacity;
    const owner = try allocator.create(zrx.HttpServer);
    errdefer allocator.destroy(owner);
    owner.* = .init(allocator, httpConfig(settings, options));
    try owner.acquire(io);
    errdefer owner.release(io);
    var buffer: [256]u8 = undefined;
    var output = options.console.writerStreaming(io, &buffer);
    const message = try zrx.Line(256).fromFormat("ready http://{f}", .{owner.address()});
    // Keep the file writer's underlying error, especially cancellation during
    // acquisition, instead of exposing only the erased interface's WriteFailed.
    try zrx.writeLine(&output, message);
    return .{ .server = owner };
}

fn closeServer(allocator: std.mem.Allocator, io: std.Io, value: Server) void {
    value.server.release(io);
    allocator.destroy(value.server);
}

pub fn server(options: ServerOptions) @TypeOf(resource(options, openServer, closeServer)) {
    return resource(options, openServer, closeServer);
}

fn httpConfig(settings: commands.Config, options: ServerOptions) zrx.HttpServerConfig {
    return .{
        .address = .{ .ip4 = .loopback(settings.port) },
        .connection_budget = settings.connections,
        .request_body_bytes = settings.body_bytes,
        .head_bytes = 4096,
        .target_bytes = 128,
        .header_count = 16,
        .response_body_bytes = 256,
        .response_header_bytes = 256,
        .response_header_count = 4,
        .head_timeout = .fromSeconds(2),
        .request_timeout = .fromSeconds(5),
        .ready = options.ready,
        .stop = options.stop,
    };
}
