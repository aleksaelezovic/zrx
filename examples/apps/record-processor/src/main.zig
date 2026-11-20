const std = @import("std");
const app = @import("app");

pub fn main(init: std.process.Init) u8 {
    var exit: app.Exit = .{};
    if (init.minimal.args.toSlice(init.arena.allocator())) |args| {
        app.execute(init.io, args[1..], &exit);
    } else |err| app.refuse(init.io, &exit, err);
    return exit.code;
}
