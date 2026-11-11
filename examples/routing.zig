//! Exclusive cases with `route`, fan-out with `branch`, and predicates built
//! from library combinators instead of hand-written functions.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const fold = zrx.fold;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const branch = zrx.branch;
const compose = zrx.compose;
const field = zrx.field;
const eq = zrx.eq;
const ge = zrx.ge;
const stdout = zrx.stdout;
const print = zrx.print;

const Kind = enum { sale, refund };
const Order = struct { id: u32, kind: Kind, cents: i64 };

const isRefund = compose(.{ field(.kind), eq(Kind.refund) });
const isLarge = compose(.{ field(.cents), ge(10_000) });

fn negated(order: Order) i64 {
    return -order.cents;
}
fn withFee(order: Order) i64 {
    return order.cents - 250;
}
fn add(sum: i64, cents: i64) i64 {
    return sum + cents;
}
fn idAndCents(order: Order) struct { u32, i64 } {
    return .{ order.id, order.cents };
}

/// What each order contributes to revenue; every case emits cents, so the
/// pipe continues after the route.
const revenue = pipe(.{
    route(.{
        when(isRefund, pipe(.{map(negated)})),
        when(isLarge, pipe(.{map(withFee)})),
        otherwise(pipe(.{map(field(.cents))})),
    }),
    fold(0, add),
    print(zrx.Stdout, "revenue: {d}\n"),
});

/// Every order as it arrives.
const journal = pipe(.{ map(idAndCents), print(zrx.Stdout, "order {d}: {d}\n") });

pub fn main(init: std.process.Init) !void {
    const orders = [_]Order{
        .{ .id = 1, .kind = .sale, .cents = 4_000 },
        .{ .id = 2, .kind = .sale, .cents = 25_000 },
        .{ .id = 3, .kind = .refund, .cents = 4_000 },
    };
    const app = program(fromSlice(&orders), pipe(.{ stdout(256), branch(.{ journal, revenue }) }));
    try app.run(.{init.io});
}
