const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;

test {
    _ = http.path(7);
}
