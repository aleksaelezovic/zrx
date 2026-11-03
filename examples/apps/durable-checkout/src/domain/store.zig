//! One local SQLite transaction owns key, full input identity and receipt.
//! BEGIN IMMEDIATE serializes check/insert across processes; a UNIQUE key is
//! the final invariant. No callback to a remote system occurs in a transaction.
//! An error before successful COMMIT attempts rollback. A failed/ambiguous COMMIT
//! is NOT proof of non-issuance: retry the same key/input to resolve the result.
const std = @import("std");
const sql = @import("sqlite_c");
const Request = @import("request.zig").Request;
const Result = @import("result.zig").Result;
const Fault = @import("fault.zig").Fault;

pub const Error = error{ Storage, Busy, Conflict, IncompatibleDatabase, InvalidRequest, InvalidDatabasePath, InjectedFailure };
pub const Config = struct {
    path: [:0]const u8,
    fault: Fault = .none,
};

pub const Store = struct {
    db: *sql.sqlite3,
    fault: Fault,

    /// Open and configure an owned connection. The app's managed resource calls
    /// this only for checkout commands and closes it after all serial users stop.
    pub fn open(config: Config) Error!Store {
        if (config.path.len == 0 or std.mem.eql(u8, config.path, ":memory:") or
            std.mem.indexOfScalar(u8, config.path, 0) != null) return error.InvalidDatabasePath;
        var db: ?*sql.sqlite3 = null;
        const rc = sql.sqlite3_open_v2(config.path, &db, sql.SQLITE_OPEN_READWRITE | sql.SQLITE_OPEN_CREATE, null);
        if (rc != sql.SQLITE_OK) {
            if (db) |handle| _ = sql.sqlite3_close(handle);
            try check(rc);
            return error.Storage;
        }
        const store = Store{ .db = db orelse return error.Storage, .fault = config.fault };
        errdefer store.close();
        // Bounded SQLite lock wait, not a retry policy or crash-test scheduler.
        try check(sql.sqlite3_busy_timeout(store.db, 250));
        try store.initialize();
        return store;
    }

    pub fn close(self: Store) void {
        // All prepared statements are finalized before this managed release.
        _ = sql.sqlite3_close(self.db);
    }

    pub fn issue(self: Store, request: Request) Error!Result {
        try request.validate();
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        if (self.fault == .after_begin) std.c._Exit(85);

        if (try self.lookup(request)) |id| {
            try self.commit();
            return .{ .checkout_id = id, .request = request, .reused = true };
        }
        const id = try self.insert(request);
        if (self.fault == .after_insert) {
            // Force dirty pages out while the transaction is still uncommitted.
            // The restart must recover an on-disk journal, not just lose RAM.
            try check(sql.sqlite3_db_cacheflush(self.db));
            std.c._Exit(86);
        }
        if (self.fault == .rollback) return error.InjectedFailure;
        try self.commit();
        return .{ .checkout_id = id, .request = request, .reused = false };
    }

    fn commit(self: Store) Error!void {
        try self.exec("COMMIT");
        // The process may die here without ever acknowledging the durable row.
        if (self.fault == .after_commit) std.c._Exit(87);
    }

    fn lookup(self: Store, request: Request) Error!?i64 {
        const statement = try self.prepare("SELECT id, cart, cents FROM checkouts WHERE key = ?1");
        defer _ = sql.sqlite3_finalize(statement);
        try bindText(statement, 1, request.key);
        const rc = sql.sqlite3_step(statement);
        if (rc == sql.SQLITE_DONE) return null;
        try expectRow(rc);
        if (!std.mem.eql(u8, try text(statement, 1), request.cart) or
            sql.sqlite3_column_int64(statement, 2) != request.cents) return error.Conflict;
        const id = sql.sqlite3_column_int64(statement, 0);
        if (id <= 0) return error.Storage;
        return id;
    }

    fn insert(self: Store, request: Request) Error!i64 {
        const statement = try self.prepare("INSERT INTO checkouts(key, cart, cents) VALUES (?1, ?2, ?3)");
        defer _ = sql.sqlite3_finalize(statement);
        try bindText(statement, 1, request.key);
        try bindText(statement, 2, request.cart);
        try check(sql.sqlite3_bind_int64(statement, 3, request.cents));
        const rc = sql.sqlite3_step(statement);
        if (rc != sql.SQLITE_DONE) {
            try check(rc);
            return error.Storage;
        }
        const id = sql.sqlite3_last_insert_rowid(self.db);
        if (id <= 0) return error.Storage;
        return id;
    }

    fn exec(self: Store, query: [:0]const u8) Error!void {
        try check(sql.sqlite3_exec(self.db, query, null, null, null));
    }

    fn prepare(self: Store, query: [:0]const u8) Error!*sql.sqlite3_stmt {
        var statement: ?*sql.sqlite3_stmt = null;
        try check(sql.sqlite3_prepare_v2(self.db, query, -1, &statement, null));
        return statement orelse error.Storage;
    }

    fn integer(self: Store, query: [:0]const u8) Error!i64 {
        const statement = try self.prepare(query);
        defer _ = sql.sqlite3_finalize(statement);
        try expectRow(sql.sqlite3_step(statement));
        return sql.sqlite3_column_int64(statement, 0);
    }

    fn initialize(self: Store) Error!void {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const version = try self.integer("PRAGMA user_version");
        const application = try self.integer("PRAGMA application_id");
        if (version == 0 and application == 0) {
            // Do not adopt an unrelated database, even if it is unversioned.
            if (try self.integer("SELECT count(*) FROM sqlite_schema") != 0)
                return error.IncompatibleDatabase;
            try self.exec(
                \\CREATE TABLE checkouts (
                \\  id INTEGER PRIMARY KEY CHECK(id > 0),
                \\  key TEXT NOT NULL UNIQUE CHECK(length(key) BETWEEN 1 AND 64),
                \\  cart TEXT NOT NULL CHECK(length(cart) BETWEEN 1 AND 64),
                \\  cents INTEGER NOT NULL CHECK(cents BETWEEN 1 AND 4294967295)
                \\) STRICT;
                \\PRAGMA application_id = 1515340619;
                \\PRAGMA user_version = 1;
            );
        } else if (version != 1 or application != 1515340619) {
            return error.IncompatibleDatabase;
        }
        // Validate the expected columns without scanning historical receipts.
        const schema = try self.prepare("SELECT id, key, cart, cents FROM checkouts LIMIT 0");
        _ = sql.sqlite3_finalize(schema);
        try self.exec("COMMIT");
        const statement = try self.prepare("PRAGMA journal_mode = DELETE");
        defer _ = sql.sqlite3_finalize(statement);
        try expectRow(sql.sqlite3_step(statement));
        if (!std.mem.eql(u8, try text(statement, 0), "delete")) return error.Storage;
        try self.exec("PRAGMA synchronous = FULL");
        if (try self.integer("PRAGMA synchronous") != 2) return error.Storage;
    }
};

fn check(rc: c_int) Error!void {
    switch (rc & 0xff) {
        sql.SQLITE_OK => {},
        sql.SQLITE_BUSY, sql.SQLITE_LOCKED => return error.Busy,
        else => return error.Storage,
    }
}

fn expectRow(rc: c_int) Error!void {
    if (rc == sql.SQLITE_ROW) return;
    try check(rc);
    // Successful execution without the required row is not a valid result.
    return error.Storage;
}

test "required row steps preserve SQLite errors and reject missing rows" {
    try expectRow(sql.SQLITE_ROW);
    for ([_]c_int{ sql.SQLITE_BUSY, sql.SQLITE_BUSY_RECOVERY, sql.SQLITE_LOCKED, sql.SQLITE_LOCKED_SHAREDCACHE }) |rc| {
        try std.testing.expectError(error.Busy, expectRow(rc));
    }
    for ([_]c_int{ sql.SQLITE_DONE, sql.SQLITE_OK, sql.SQLITE_IOERR_READ, sql.SQLITE_CORRUPT }) |rc| {
        try std.testing.expectError(error.Storage, expectRow(rc));
    }
}

fn bindText(statement: *sql.sqlite3_stmt, index: c_int, value: []const u8) Error!void {
    // Request bytes remain stable until this statement is finalized.
    try check(sql.sqlite3_bind_text(statement, index, value.ptr, @intCast(value.len), sql.SQLITE_STATIC));
}

fn text(statement: *sql.sqlite3_stmt, column: c_int) Error![]const u8 {
    const ptr = sql.sqlite3_column_text(statement, column);
    if (ptr == null) return error.Storage;
    const length = sql.sqlite3_column_bytes(statement, column);
    if (length < 0) return error.Storage;
    return ptr[0..@intCast(length)];
}
