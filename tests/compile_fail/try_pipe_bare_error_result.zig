const zrx = @import("zrx");

fn errorData(_: u32) error{Data} {
    return error.Data;
}

fn consume(_: error{Data}) u32 {
    return 1;
}

test {
    // Reject even an intermediate bare error set, so grouping never changes
    // whether this unsupported success-payload type is accepted.
    _ = zrx.tryPipe(1, .{zrx.map(.{ errorData, consume })});
}
