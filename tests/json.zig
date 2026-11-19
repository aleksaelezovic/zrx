//! `zrx.ext.json`: items as JSON text.
const std = @import("std");
const zrx = @import("zrx");
const io = std.testing.io;

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const range = zrx.range;
const map = zrx.map;
const compose = zrx.compose;
const queue = zrx.queue;
const print = zrx.print;
const write = zrx.write;
const json = zrx.ext.json;

const Archive = struct { writer: *std.Io.Writer };

const Name = zrx.Line(8);
const Pet = struct { name: Name, legs: u32 };

fn named(text: []const u8) !Pet {
    return .{ .name = try .from(text), .legs = 4 };
}

test "encode writes each item as a line of JSON, a Line field as a string" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const names = [_][]const u8{ "rex", "", "judy \"j\"" };
    const archive = pipe(.{
        map(named),
        map(json.encode(.{})),
        write(Archive, "{f}\n"),
    });
    try program(fromSlice(&names), archive).run(.{Archive{ .writer = &writer }});
    try std.testing.expectEqualStrings(
        \\{"name":"rex","legs":4}
        \\{"name":"","legs":4}
        \\{"name":"judy \"j\"","legs":4}
        \\
    , writer.buffered());
}

const Row = struct { path: []const u8, size: ?u64 = null, failure: ?[]const u8 = null };

const rows = [_]Row{
    .{ .path = "a.txt", .size = 12 },
    .{ .path = "b.txt", .failure = "FileNotFound" },
};

test "encode writes a null optional field by default" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try program(fromSlice(&rows), .{ map(json.encode(.{})), write(*std.Io.Writer, "{f}\n") }).run(.{&writer});
    try std.testing.expectEqualStrings(
        \\{"path":"a.txt","size":12,"failure":null}
        \\{"path":"b.txt","size":null,"failure":"FileNotFound"}
        \\
    , writer.buffered());
}

test "encode leaves a null optional field out when its options say so" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const compact = json.encode(.{ .emit_null_optional_fields = false });
    try program(fromSlice(&rows), .{ map(compact), write(*std.Io.Writer, "{f}\n") }).run(.{&writer});
    try std.testing.expectEqualStrings(
        \\{"path":"a.txt","size":12}
        \\{"path":"b.txt","failure":"FileNotFound"}
        \\
    , writer.buffered());
}

test "encode passes every option on to std.json" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const words = [_][]const u8{"hi"};
    const options: std.json.Stringify.Options = .{ .whitespace = .indent_1, .emit_strings_as_arrays = true };
    try program(fromSlice(&words), .{ map(json.encode(options)), print(*std.Io.Writer, "{f}\n") }).run(.{&writer});
    try std.testing.expectEqualStrings(
        \\[
        \\ 104,
        \\ 105
        \\]
        \\
    , writer.buffered());
}

fn square(value: u32) u32 {
    return value * value;
}

test "encode is a handler like any other: it composes and takes any item std.json can write" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const squared = compose(.{ square, json.encode(.{}) });
    try program(range(u32, 1, 4), .{ map(squared), print(*std.Io.Writer, "{f},") }).run(.{&writer});
    try std.testing.expectEqualStrings("1,4,9,", writer.buffered());
}

test "encoded text is an item that owns a copy of its value, so it crosses a queue" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const names = [_][]const u8{ "rex", "judy" };
    const archive = pipe(.{
        map(named),
        map(json.encode(.{})),
        queue(1),
        write(Archive, "{f}\n"),
    });
    try program(fromSlice(&names), archive).run(.{ io, Archive{ .writer = &writer } });
    try std.testing.expectEqualStrings(
        \\{"name":"rex","legs":4}
        \\{"name":"judy","legs":4}
        \\
    , writer.buffered());
}
