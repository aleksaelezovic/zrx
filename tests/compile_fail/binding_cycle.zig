const zrx = @import("zrx");

const Connection = struct { id: u32 };
const Session = struct { id: u32 };

fn connect(session: Session) Connection {
    return .{ .id = session.id };
}
fn openSession(connection: Connection) Session {
    return .{ .id = connection.id };
}
fn ignore(_: Session, _: u32) void {}

test "two resources need each other" {
    const app = zrx.program(zrx.range(u32, 0, 3), .{zrx.forEach(ignore)}).provide(.{zrx.resource(openSession, null)});
    try app.run(.{zrx.resource(connect, null)});
}
