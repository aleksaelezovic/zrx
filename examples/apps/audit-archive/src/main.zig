const std = @import("std");
const app = @import("app");

pub fn main(init: std.process.Init) u8 {
    var exit: app.Exit = .{};
    if (init.minimal.args.toSlice(init.arena.allocator())) |args| {
        if (args.len == 3) {
            app.run(init.io, args[1], args[2], &exit);
        } else {
            app.refuse(init.io, &exit, error.InvalidArguments);
        }
    } else |err| app.refuse(init.io, &exit, err);
    return exit.code;
}
