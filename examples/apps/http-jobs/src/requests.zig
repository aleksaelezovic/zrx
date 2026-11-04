//! Request-correlated ordinary handlers, not custom operators or error recovery.
//! Every envelope lives only in the exclusive request lane. Client failures are
//! explicit data WITH the capability; infrastructure errors still fail run.
const std = @import("std");
const zrx = @import("zrx");
const jobs = @import("domain/jobs.zig");
const Config = @import("domain/commands.zig").Config;
const routes = @import("domain/routes.zig");
const Store = @import("store.zig").Store;
const response = @import("response.zig");

pub const Submission = struct {
    request: zrx.HttpRequest,
    input: union(enum) { body: []const u8, rejected: response.Rejection },
};

pub fn readSubmission(request: zrx.HttpRequest) !Submission {
    const content_type = request.uniqueHeader("content-type") catch
        return .{ .request = request, .input = .{ .rejected = .expected_json } };
    var encoding = request.headerValues("content-encoding");
    if (!routes.acceptsJson(content_type, encoding.next() != null))
        return .{ .request = request, .input = .{ .rejected = .expected_json } };
    const body = request.readRemainingBody() catch |err| switch (err) {
        error.HttpBodyTooLarge => return .{ .request = request, .input = .{ .rejected = .body_too_large } },
        error.HttpInvalidBody => return .{ .request = request, .input = .{ .rejected = .invalid_body } },
        else => return err,
    };
    return .{ .request = request, .input = .{ .body = body } };
}

pub const Validated = struct {
    request: zrx.HttpRequest,
    input: union(enum) { job: jobs.Job, rejected: response.Rejection },
};

pub fn validateSubmission(allocator: std.mem.Allocator, settings: Config, submission: Submission) !Validated {
    const job = switch (submission.input) {
        .rejected => |failure| return .{ .request = submission.request, .input = .{ .rejected = failure } },
        .body => |body| jobs.decode(allocator, settings.max_values, body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJob => return .{ .request = submission.request, .input = .{ .rejected = .invalid_job } },
        },
    };
    return .{ .request = submission.request, .input = .{ .job = job } };
}

/// The mutation is visibly separate from validation and response formatting.
/// Delivery may still fail AFTER this effect; no rollback or retry is implied.
pub fn recordJob(store: *Store, validated: Validated) response.Reply {
    const record = switch (validated.input) {
        .rejected => |failure| return .{ .request = validated.request, .outcome = .{ .rejected = failure } },
        .job => |job| store.submit(job) catch |err| switch (err) {
            error.StoreFull => return .{ .request = validated.request, .outcome = .{ .rejected = .store_full } },
        },
    };
    return .{ .request = validated.request, .outcome = .{ .created = record } };
}

pub const Lookup = struct {
    request: zrx.HttpRequest,
    id: ?u64,
};

/// Selected only by the explicit "/jobs/" target-prefix cases.
pub fn parseJobId(request: zrx.HttpRequest) Lookup {
    return .{ .request = request, .id = routes.jobId(request.target["/jobs/".len..]) catch null };
}

pub fn lookupJob(store: *Store, lookup: Lookup) response.Reply {
    const id = lookup.id orelse return .{ .request = lookup.request, .outcome = .{ .rejected = .invalid_id } };
    const record = store.lookup(id) catch |err| switch (err) {
        error.NotFound => return .{ .request = lookup.request, .outcome = .{ .rejected = .not_found } },
    };
    return .{ .request = lookup.request, .outcome = .{ .found = record } };
}

pub fn methodNotAllowedPost(request: zrx.HttpRequest) response.Reply {
    return .{ .request = request, .outcome = .{ .method_not_allowed = "POST" } };
}

pub fn methodNotAllowedGet(lookup: Lookup) response.Reply {
    if (lookup.id == null) return .{ .request = lookup.request, .outcome = .{ .rejected = .invalid_id } };
    return .{ .request = lookup.request, .outcome = .{ .method_not_allowed = "GET" } };
}

pub fn notFound(request: zrx.HttpRequest) response.Reply {
    return .{ .request = request, .outcome = .{ .rejected = .not_found } };
}
