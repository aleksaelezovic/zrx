const std = @import("std");
const zrx = @import("zrx");
export fn declarative_file_copy(gpa: *const std.mem.Allocator, io: *const std.Io, input: [*]const u8, input_len: usize, output: [*]const u8, output_len: usize) bool {
    const source = zrx.fileLines(input[0..input_len], 64, 1);
    const flow = zrx.pipe(source, .{zrx.writeFileLines(output[0..output_len], .{ .exclusive = true })});
    zrx.run(.{ gpa.*, io.* }, .{flow}) catch return false;
    return true;
}
