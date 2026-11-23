//! Exclusive cases with `route`, fan-out with `branch`, and handlers built
//! from library combinators instead of hand-written functions.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const rescue = zrx.rescue;
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
const print = zrx.print;
const math = zrx.ext.math;
const neg = math.neg;
const sub = math.sub;
const sum = math.sum;
const process = zrx.ext.process;
const stdout = process.stdout;
const Stdout = process.Stdout;

const Kind = enum { sale, refund };
const Order = struct { id: u32, kind: Kind, cents: i64 };

const isRefund = compose(.{ field(.kind), eq(Kind.refund) });
const isLarge = compose(.{ field(.cents), ge(10_000) });

const cents = field(.cents);
const negated = compose(.{ cents, neg });
const withFee = compose(.{ cents, sub(250) });

fn idAndCents(order: Order) struct { u32, i64 } {
    return .{ order.id, order.cents };
}

/// What each order contributes to revenue; every case emits cents, so the
/// pipe continues after the route.
const revenue = pipe(.{
    route(.{
        when(isRefund, .{map(negated)}),
        when(isLarge, .{map(withFee)}),
        otherwise(.{map(cents)}),
    }),
    fold(0, sum),
    print(Stdout, "revenue: {d}\n"),
});

/// Every order as it arrives.
const journal = pipe(.{
    map(idAndCents),
    print(Stdout, "order {d}: {d}\n"),
});

pub fn main(init: std.process.Init) u8 {
    var exit: process.Exit = .{};
    const orders = [_]Order{
        .{ .id = 1, .kind = .sale, .cents = 4_000 },
        .{ .id = 2, .kind = .sale, .cents = 25_000 },
        .{ .id = 3, .kind = .refund, .cents = 4_000 },
    };
    const app = program(fromSlice(&orders), .{
        branch(.{
            journal,
            revenue,
        }),
    }).provide(.{stdout(Stdout, 256)});
    // A run returns nothing: what ends it goes to a rescue, and here becomes
    // the exit status.
    app.run(.{ init.io, &exit, rescue(process.fail(.{ .prefix = null })) });
    return exit.code;
}
