const zrx = @import("zrx");

const Connection = struct { id: u32 };
const Session = struct { id: u32 };
const Limit = struct { max: u32 };

fn openSession(connection: Connection) Session {
    return .{ .id = connection.id };
}
fn ignore(_: Session, _: u32) void {}

test "a resource needs something nobody provides" {
    const app = zrx.program(zrx.range(u32, 0, 3), .{zrx.forEach(ignore)}).provide(.{zrx.resource(openSession, null)});
    app.run(.{Limit{ .max = 1 }});
}
