const std = @import("std");
const sql = @import("sqlite_c");

test "generated header and linked SQLite match the pinned amalgamation version" {
    try std.testing.expectEqual(@as(c_int, 3054001), sql.SQLITE_VERSION_NUMBER);
    try std.testing.expectEqual(@as(c_int, sql.SQLITE_VERSION_NUMBER), sql.sqlite3_libversion_number());
}

test "linked SQLite preserves the configured build policy" {
    for ([_][*:0]const u8{ "THREADSAFE=1", "DQS=0", "OMIT_LOAD_EXTENSION" }) |option| {
        try std.testing.expectEqual(@as(c_int, 1), sql.sqlite3_compileoption_used(option));
    }
}
