const zrx = @import("zrx");
const Line = zrx.Line;
const line = zrx.line;
const pipe = zrx.pipe;
const map = zrx.map;

fn checksum(value: Line(32)) u32 {
    var result: u32 = 0;
    for (value.bytes[0..value.len]) |byte| result +%= byte;
    return result;
}

export fn line_value(source: [*]const u8, len: usize) u32 {
    const value = line(32, source[0..len]) catch return 0xffffffff;
    return pipe(value, .{map(checksum)});
}
