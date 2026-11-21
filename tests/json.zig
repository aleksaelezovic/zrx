//! `zrx.ext.json`: items as JSON text, and items from JSON text.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");
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
    try support.run(program(fromSlice(&names), archive), .{Archive{ .writer = &writer }});
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
    try support.run(program(fromSlice(&rows), .{ map(json.encode(.{})), write(*std.Io.Writer, "{f}\n") }), .{&writer});
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
    try support.run(program(fromSlice(&rows), .{ map(compact), write(*std.Io.Writer, "{f}\n") }), .{&writer});
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
    try support.run(program(fromSlice(&words), .{ map(json.encode(options)), print(*std.Io.Writer, "{f}\n") }), .{&writer});
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
    try support.run(program(range(u32, 1, 4), .{ map(squared), print(*std.Io.Writer, "{f},") }), .{&writer});
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
    try support.run(program(fromSlice(&names), archive), .{ io, Archive{ .writer = &writer } });
    try std.testing.expectEqualStrings(
        \\{"name":"rex","legs":4}
        \\{"name":"judy","legs":4}
        \\
    , writer.buffered());
}

// --- decode ---------------------------------------------------------------------------------------

const lines = zrx.lines;
const forEach = zrx.forEach;
const drain = zrx.drain;
const field = zrx.field;
const orElse = zrx.orElse;
const recover = zrx.recover;
const attempt = zrx.attempt;

const Kind = enum { cat, dog };
const Animal = struct { name: Name, legs: u8, kind: Kind = .cat, code: [2]u8 = "--".*, ratio: f32 = 0 };
const Animals = support.Recorder(Animal);
const Errors = support.Recorder(anyerror);

fn expectAnimal(expected: struct { []const u8, u8, Kind }, actual: Animal) !void {
    try std.testing.expectEqualStrings(expected[0], actual.name.text());
    try std.testing.expectEqual(expected[1], actual.legs);
    try std.testing.expectEqual(expected[2], actual.kind);
}

/// Room for any text of these tests that is meant to be read.
const animal = json.decode(Animal, .{ .scratch = 1024 });

test "decode reads each text as a value, a string as a Line field" {
    var seen: Animals = .{};
    const texts = [_][]const u8{
        \\{"name":"rex","legs":4,"kind":"dog"}
        ,
        \\ { "legs" : 2 , "name" : "" , "ratio" : 0.5 , "code" : "ab" }
        ,
        \\{"name":"judy \"j\"","legs":"4","kind":1}
    };
    try support.run(program(fromSlice(&texts), .{ map(animal), forEach(support.record(Animal)) }), .{&seen});
    try std.testing.expectEqual(3, seen.len);
    try expectAnimal(.{ "rex", 4, .dog }, seen.items[0]);
    try expectAnimal(.{ "", 2, .cat }, seen.items[1]);
    try std.testing.expectEqual(0.5, seen.items[1].ratio);
    try std.testing.expectEqualStrings("ab", &seen.items[1].code);
    // What `std.json` takes besides the plain spelling: a number as a string, an enum by its number.
    try expectAnimal(.{ "judy \"j\"", 4, .dog }, seen.items[2]);
}

test "decode reads the text of a Line, and what it read crosses a queue and is encoded again" {
    var reader: std.Io.Reader = .fixed(
        \\{"name":"r\u0065x","legs":4}
        \\{"legs":"4","name":[106,117,100,121]}
        \\
    );
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const copy = pipe(.{
        map(json.decode(Pet, .{ .scratch = 1024 })),
        queue(1),
        map(json.encode(.{})),
        write(*std.Io.Writer, "{f}\n"),
    });
    try support.run(program(lines(*std.Io.Reader, 64), copy), .{ io, &reader, &writer });
    try std.testing.expectEqualStrings(
        \\{"name":"rex","legs":4}
        \\{"name":"judy","legs":4}
        \\
    , writer.buffered());
}

const Shape = union(enum) { circle: f32, square: struct { side: u16 }, point };
const Drawing = struct { shapes: [3]Shape, visible: bool, layer: ?i8, size: struct { u8, u8 } };

test "decode reads whatever std.json reads that is a value" {
    const texts = [_][]const u8{
        \\{"shapes":[{"circle":1.5},{"square":{"side":2}},{"point":{}}],"visible":true,"layer":null,"size":[3,4]}
    };
    var seen: support.Recorder(Drawing) = .{};
    try support.run(program(fromSlice(&texts), .{ map(json.decode(Drawing, .{ .scratch = 1024 })), forEach(support.record(Drawing)) }), .{&seen});
    try std.testing.expectEqualDeep(Drawing{
        .shapes = .{ .{ .circle = 1.5 }, .{ .square = .{ .side = 2 } }, .point },
        .visible = true,
        .layer = null,
        .size = .{ 3, 4 },
    }, seen.items[0]);
}

test "decode passes its parse options on to std.json" {
    var seen: Animals = .{};
    const texts = [_][]const u8{
        \\{"name":"rex","legs":4,"legs":3,"tail":{"long":[true]}}
    };
    const lenient = json.decode(Animal, .{ .scratch = 1024, .parse = .{ .ignore_unknown_fields = true, .duplicate_field_behavior = .use_last } });
    try support.run(program(fromSlice(&texts), .{ map(lenient), forEach(support.record(Animal)) }), .{&seen});
    try expectAnimal(.{ "rex", 3, .cat }, seen.items[0]);
}

const Envelope = struct { id: u32, body: []const u8 };

test "decode is a handler like any other: it composes with the one that yields the text" {
    var seen: Animals = .{};
    const envelopes = [_]Envelope{.{ .id = 1, .body = "{\"name\":\"rex\",\"legs\":4}" }};
    const body = compose(.{ field(.body), animal });
    try support.run(program(fromSlice(&envelopes), .{ map(body), forEach(support.record(Animal)) }), .{&seen});
    try expectAnimal(.{ "rex", 4, .cat }, seen.items[0]);
}

/// A name of more bytes than the scratch memory has, written with an escape
/// so that `std.json` has to copy it there.
const long_name: [2000]u8 = @splat('a');
const too_much = "{\"name\":\"\\n" ++ long_name ++ "\",\"legs\":4}";

/// One text for every error `std.json` has for one whole text.
const failing = [_]struct { []const u8, json.DecodeError }{
    .{ "rex", error.SyntaxError },
    .{ "{\"name\":\"rex\",\"legs\":4} {}", error.SyntaxError },
    .{ "", error.UnexpectedEndOfInput },
    .{ "{\"name\":\"rex\"", error.UnexpectedEndOfInput },
    .{ "{\"name\":\"rex\",\"legs\":true}", error.UnexpectedToken },
    .{ "{\"name\":\"rex\",\"legs\":1.5}", error.InvalidNumber },
    .{ "{\"name\":\"rex\",\"legs\":\"four\"}", error.InvalidCharacter },
    .{ "{\"name\":\"rex\",\"legs\":256}", error.Overflow },
    .{ "{\"name\":\"rex\",\"legs\":4,\"kind\":\"bird\"}", error.InvalidEnumTag },
    .{ "{\"name\":\"rex\",\"legs\":4,\"legs\":4}", error.DuplicateField },
    .{ "{\"name\":\"rex\",\"legs\":4,\"tail\":1}", error.UnknownField },
    .{ "{\"name\":\"rex\"}", error.MissingField },
    .{ "{\"name\":\"rex\",\"legs\":4,\"code\":\"abc\"}", error.LengthMismatch },
    .{ "{\"name\":\"rex the ninth\",\"legs\":4}", error.ValueTooLong },
    .{ too_much, error.OutOfMemory },
};

fn failingTexts() [failing.len + 1][]const u8 {
    var texts: [failing.len + 1][]const u8 = undefined;
    for (failing, texts[0..failing.len]) |case, *text| text.* = case[0];
    texts[failing.len] = "{\"name\":\"rex\",\"legs\":4}";
    return texts;
}

fn expectFailures(errors: *const Errors) !void {
    try std.testing.expectEqual(failing.len, errors.len);
    for (failing, errors.slice()) |case, err| try std.testing.expectEqual(@as(anyerror, case[1]), err);
}

fn noteFailure(errors: *Errors, failed: zrx.Failed(json.DecodeError, []const u8)) void {
    errors.add(failed.err);
}

test "every failure of std.json is an error an error path takes, and the texts after it are read" {
    var seen: Animals = .{};
    var errors: Errors = .{};
    const texts = failingTexts();
    const read = pipe(.{
        recover(json.DecodeError, .{forEach(noteFailure)}),
        map(animal),
        forEach(support.record(Animal)),
    });
    // Nothing is left: this compiles without a rescue.
    program(fromSlice(&texts), read).run(.{ &seen, &errors });
    try expectFailures(&errors);
    try std.testing.expectEqual(1, seen.len);
    try expectAnimal(.{ "rex", 4, .cat }, seen.items[0]);
}

const ShapeError = error{ UnknownField, MissingField, DuplicateField };

fn unnamed(errors: *Errors, failed: zrx.Failed(ShapeError, []const u8)) Animal {
    errors.add(failed.err);
    return .{ .name = Name.from("?") catch unreachable, .legs = 0 };
}

test "attempt takes the errors of std.json it names and leaves the others" {
    var seen: Animals = .{};
    var errors: Errors = .{};
    const texts = [_][]const u8{
        \\{"name":"rex"}
        ,
        \\{"name":"rex","legs":4,"tail":1}
        ,
        \\{"name":"rex","legs":"four"}
        ,
        \\{"name":"rex","legs":4}
    };
    const read = program(fromSlice(&texts), .{
        attempt(.{map(animal)}, ShapeError, .{map(unnamed)}),
        forEach(support.record(Animal)),
    });
    const left = support.runLeft(read, .{ &seen, &errors });
    try std.testing.expectEqualStrings(
        "InvalidCharacter InvalidEnumTag InvalidNumber LengthMismatch OutOfMemory Overflow SyntaxError UnexpectedEndOfInput UnexpectedToken ValueTooLong ",
        left.names(),
    );
    try std.testing.expectEqual(error.InvalidCharacter, left.err.?);
    try errors.expect(&.{ error.MissingField, error.UnknownField });
    try std.testing.expectEqual(2, seen.len);
    try expectAnimal(.{ "?", 0, .cat }, seen.items[1]);
}

fn nameless(errors: *Errors, err: json.DecodeError, _: []const u8) Animal {
    errors.add(err);
    return .{ .name = Name.from("?") catch unreachable, .legs = 0 };
}

test "orElse keeps a text that is not read as a value, whatever std.json failed with" {
    var seen: Animals = .{};
    var errors: Errors = .{};
    const texts = failingTexts();
    program(fromSlice(&texts), .{ map(orElse(animal, nameless)), forEach(support.record(Animal)) }).run(.{ &seen, &errors });
    try expectFailures(&errors);
    try std.testing.expectEqual(failing.len + 1, seen.len);
    try expectAnimal(.{ "?", 0, .cat }, seen.items[0]);
    try expectAnimal(.{ "rex", 4, .cat }, seen.items[failing.len]);
}

test "what decode fails with is what std.json fails with for one whole text, and no more" {
    var seen: Animals = .{};
    const texts = [_][]const u8{"rex"};
    const left = support.runLeft(program(fromSlice(&texts), .{ map(animal), forEach(support.record(Animal)) }), .{&seen});
    try std.testing.expectEqual(error.SyntaxError, left.err.?);
    try std.testing.expectEqualStrings(
        "DuplicateField InvalidCharacter InvalidEnumTag InvalidNumber LengthMismatch MissingField OutOfMemory Overflow SyntaxError UnexpectedEndOfInput UnexpectedToken UnknownField ValueTooLong ",
        left.names(),
    );
    // `BufferUnderrun` is the one `std.json` lists and never fails a whole text with.
    comptime {
        const possible = @typeInfo(std.json.ParseError(std.json.Scanner)).error_set.error_names.?;
        const written = @typeInfo(json.DecodeError).error_set.error_names.?;
        std.debug.assert(possible.len == written.len + 1);
        for (written) |name| {
            const found = for (possible) |other| {
                if (std.mem.eql(u8, name, other)) break true;
            } else false;
            std.debug.assert(found and !std.mem.eql(u8, name, "BufferUnderrun"));
        }
    }
}

test "a text that needs more scratch memory than decode was given fails with OutOfMemory, which a path takes" {
    // A number alone needs none. An escape is copied there, and so is how deep the text is nested.
    const numbers = [_][]const u8{ "7", "\"\\u0038\"", " 9 " };
    const nested = [_][]const u8{ "[[7]]", "[[8]]" };
    inline for (.{ 0, 1024 }) |scratch| {
        var seen: support.Recorder(u8) = .{};
        var errors: Errors = .{};
        const read = pipe(.{
            recover(json.DecodeError, .{forEach(noteFailure)}),
            map(json.decode(u8, .{ .scratch = scratch })),
            forEach(support.record(u8)),
        });
        program(fromSlice(&numbers), read).run(.{ &seen, &errors });
        const deep = pipe(.{
            recover(json.DecodeError, .{forEach(noteFailure)}),
            map(json.decode([1][1]u8, .{ .scratch = scratch })),
            map(innermost),
            forEach(support.record(u8)),
        });
        program(fromSlice(&nested), deep).run(.{ &seen, &errors });
        if (scratch == 0) {
            try seen.expect(&.{ 7, 9 });
            try errors.expect(&.{ error.OutOfMemory, error.OutOfMemory, error.OutOfMemory });
        } else {
            try seen.expect(&.{ 7, 8, 9, 7, 8 });
            try errors.expect(&.{});
        }
    }
}

fn innermost(nested: [1][1]u8) u8 {
    return nested[0][0];
}

test "the scratch memory is the item's: a text is read with all of it, however many came before" {
    // Each text has two escapes to copy. Were the memory the stream's, 512
    // bytes would not last 256 texts.
    const text = "{\"n\\u0061me\":\"r\\u0065x\",\"legs\":4}";
    const texts: [256][]const u8 = @splat(text);
    var seen: Animals = .{};
    try support.run(program(fromSlice(&texts), .{ map(json.decode(Animal, .{ .scratch = 512 })), forEach(support.record(Animal)) }), .{&seen});
    try std.testing.expectEqual(256, seen.len);
    try expectAnimal(.{ "rex", 4, .cat }, seen.items[255]);
}

test "std.json reads a Line as it writes one: a string or an array of numbers, copied" {
    const Named = struct { name: Name };
    const plain = try std.json.parseFromSlice(Named, std.testing.allocator, "{\"name\":\"rex\"}", .{});
    defer plain.deinit();
    try std.testing.expectEqualStrings("rex", plain.value.name.text());

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const bytes: Named = .{ .name = try .from("r\xffx") };
    try writer.print("{f}", .{std.json.fmt(bytes, .{})});
    try std.testing.expectEqualStrings("{\"name\":[114,255,120]}", writer.buffered());
    const again = try std.json.parseFromSlice(Named, std.testing.allocator, writer.buffered(), .{});
    defer again.deinit();
    try std.testing.expectEqualStrings("r\xffx", again.value.name.text());

    try std.testing.expectError(error.ValueTooLong, std.json.parseFromSlice(Named, std.testing.allocator, "{\"name\":\"123456789\"}", .{}));
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Named, std.testing.allocator, "{\"name\":7}", .{}));
}
