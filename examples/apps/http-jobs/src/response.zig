const std = @import("std");
const zrx = @import("zrx");
const jobs = @import("domain/jobs.zig");

pub const Rejection = enum { invalid_job, not_found, store_full, invalid_id, expected_json, body_too_large, invalid_body };
pub const Reply = struct {
    request: zrx.HttpRequest,
    outcome: union(enum) { created: jobs.Record, found: jobs.Record, rejected: Rejection, method_not_allowed: []const u8 },

    pub fn isCreated(self: Reply) bool {
        return self.outcome == .created;
    }
    pub fn isFound(self: Reply) bool {
        return self.outcome == .found;
    }
    pub fn isWrongMethod(self: Reply) bool {
        return self.outcome == .method_not_allowed;
    }
};
const cache_control: std.http.Header = .{ .name = "cache-control", .value = "no-store" };

pub fn rejected(comptime tag: Rejection) fn (Reply) bool {
    return struct {
        fn matches(reply: Reply) bool {
            return reply.outcome == .rejected and reply.outcome.rejected == tag;
        }
    }.matches;
}

pub fn created(reply: Reply) !zrx.HttpResponse {
    return recorded(reply.request, reply.outcome.created, true);
}
pub fn found(reply: Reply) !zrx.HttpResponse {
    return recorded(reply.request, reply.outcome.found, false);
}
pub fn badRequest(reply: Reply) !zrx.HttpResponse {
    return rejection(reply, .bad_request);
}
pub fn notFound(reply: Reply) !zrx.HttpResponse {
    return rejection(reply, .not_found);
}
pub fn storeFull(reply: Reply) !zrx.HttpResponse {
    return rejection(reply, .service_unavailable);
}
pub fn unsupportedMedia(reply: Reply) !zrx.HttpResponse {
    return rejection(reply, .unsupported_media_type);
}
pub fn bodyTooLarge(reply: Reply) !zrx.HttpResponse {
    return rejection(reply, .payload_too_large);
}
pub fn methodNotAllowed(reply: Reply) !zrx.HttpResponse {
    return reply.request.jsonResponse(.{ .@"error" = "method_not_allowed" }, .{
        .status = .method_not_allowed,
        .headers = &.{ cache_control, .{ .name = "allow", .value = reply.outcome.method_not_allowed } },
        .newline = true,
    });
}
pub fn unhandled(_: Reply) !zrx.HttpResponse {
    return error.UnhandledReply;
}

fn rejection(reply: Reply, status: std.http.Status) !zrx.HttpResponse {
    return reply.request.jsonResponse(.{ .@"error" = @tagName(reply.outcome.rejected) }, .{
        .status = status,
        .headers = &.{cache_control},
        .newline = true,
    });
}

fn recorded(request: zrx.HttpRequest, record: jobs.Record, is_created: bool) !zrx.HttpResponse {
    const location = try zrx.Line(32).fromFormat("/jobs/{d}", .{record.id});
    const headers: [2]std.http.Header = .{ cache_control, .{ .name = "location", .value = location.bytes[0..location.len] } };
    return request.jsonResponse(.{
        .id = record.id,
        .label = record.job.labelText(),
        .status = "completed",
        .result = record.job.result,
    }, .{
        .status = if (is_created) .created else .ok,
        .headers = headers[0..if (is_created) 2 else 1],
        .newline = true,
    });
}
