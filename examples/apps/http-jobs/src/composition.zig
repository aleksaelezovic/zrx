//! One server pipe. Resource-specific reporting belongs to the custom server
//! resource; process completion reporting belongs after run, not in this pipe.
const zrx = @import("zrx");
const requests = @import("requests.zig");
const response = @import("response.zig");
const resources = @import("resources.zig");
const pipe = zrx.pipe;
const map = zrx.map;
const branch = zrx.branch;
const when = zrx.when;
const otherwise = zrx.otherwise;
const httpRequests = zrx.httpRequests;
const respondHttp = zrx.respondHttp;
const all = zrx.all;
const any = zrx.any;
const method = zrx.httpMethod;
const target = zrx.httpTarget;
const targetPrefix = zrx.httpTargetPrefix;
const Reply = response.Reply;
const rejected = response.rejected;

pub const program = pipe(httpRequests(resources.Server), .{
    // Raw targets intentionally include query bytes: this API does not accept
    // query parameters or decode/canonicalize path spellings.
    branch(.{
        when(all(.{ method(.POST), target("/jobs") }), .{
            map(requests.readSubmission),
            map(requests.validateSubmission),
            map(requests.recordJob),
        }),
        when(target("/jobs"), map(requests.methodNotAllowedPost)),
        when(all(.{ method(.GET), targetPrefix("/jobs/") }), .{
            map(requests.parseJobId),
            map(requests.lookupJob),
        }),
        when(targetPrefix("/jobs/"), .{
            map(requests.parseJobId),
            map(requests.methodNotAllowedGet),
        }),
        otherwise(map(requests.notFound)),
    }),
    // Every client/domain outcome keeps its request and has an explicit route.
    branch(.{
        when(Reply.isCreated, map(response.created)), // 201, Location
        when(Reply.isFound, map(response.found)), // 200
        when(any(.{ rejected(.invalid_job), rejected(.invalid_id), rejected(.invalid_body) }), map(response.badRequest)), // 400
        when(rejected(.not_found), map(response.notFound)), // 404
        when(Reply.isWrongMethod, map(response.methodNotAllowed)), // 405, Allow
        when(rejected(.body_too_large), map(response.bodyTooLarge)), // 413
        when(rejected(.expected_json), map(response.unsupportedMedia)), // 415
        when(rejected(.store_full), map(response.storeFull)), // 503
        otherwise(map(response.unhandled)), // New/unrouted outcomes fail run.
    }),
    respondHttp(),
});
