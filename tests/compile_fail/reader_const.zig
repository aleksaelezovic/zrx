const zrx = @import("zrx");
const std = @import("std");
test {
    const reader: std.Io.Reader = .fixed("");
    _ = zrx.readerLines(8, &reader);
}
