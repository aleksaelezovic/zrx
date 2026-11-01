//! One finite in-memory checkout. Application-owned keys/results make repeated
//! calls safe here; restarting the process loses them. This is not durability.
const std = @import("std");
const zrx = @import("zrx");
const fromValue = zrx.fromValue;
const retryPipe = zrx.retryPipe;
const pipe = zrx.pipe;
const map = zrx.map;
const forEach = zrx.forEach;
const run = zrx.run;

pub const Cart = struct { id: u32, cents: u32 };
const Payment = struct { cart: Cart };
const Order = struct { cart: Cart };
pub const Shipment = struct { checkout_id: u32, tracking: u32 };
pub const CheckoutError = error{ Unavailable, Declined, Conflict };
pub const Store = struct {
    payment_calls: usize = 0,
    charges: usize = 0,
    order_calls: usize = 0,
    orders: usize = 0,
    shipping_calls: usize = 0,
    shipments: usize = 0,
    payment: ?Payment = null,
    order: ?Order = null,
    shipment: ?Shipment = null,
};
pub const Payments = struct { store: *Store };
pub const Orders = struct { store: *Store };
pub const Shipping = struct { store: *Store };

fn pay(service: Payments, cart: Cart) error{ Declined, Conflict }!Payment {
    const store = service.store;
    store.payment_calls += 1;
    if (store.payment) |saved| {
        if (!std.meta.eql(saved.cart, cart)) return error.Conflict;
        return saved;
    }
    if (cart.cents == 0) return error.Declined;
    store.charges += 1;
    store.payment = .{ .cart = cart };
    return store.payment.?;
}
fn createOrder(service: Orders, payment: Payment) error{Conflict}!Order {
    const store = service.store;
    store.order_calls += 1;
    if (store.order) |saved| {
        if (!std.meta.eql(saved.cart, payment.cart)) return error.Conflict;
        return saved;
    }
    store.orders += 1;
    store.order = .{ .cart = payment.cart };
    return store.order.?;
}
fn ship(service: Shipping, order: Order) error{Unavailable}!Shipment {
    const store = service.store;
    store.shipping_calls += 1;
    if (store.shipment) |saved| return saved;
    if (store.shipping_calls < 3) return error.Unavailable;
    store.shipments += 1;
    store.shipment = .{ .checkout_id = order.cart.id, .tracking = 99 };
    return store.shipment.?;
}
fn checkoutRetryPolicy(err: CheckoutError, retries: usize) zrx.RetryDecision {
    return if (err == error.Unavailable and retries < 3) .{ .retry_after_ms = 0 } else .stop;
}
pub fn checkout(requests: anytype) @TypeOf(retryPipe(requests, .{map(.{ pay, createOrder, ship })}, checkoutRetryPolicy)) {
    return retryPipe(requests, .{map(.{ pay, createOrder, ship })}, checkoutRetryPolicy);
}
fn show(store: *Store, outcome: CheckoutError!Shipment) void {
    const shipment = outcome catch |err| {
        std.debug.print("Checkout failed: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("Checkout {d}: shipment {d}; payment calls={d} charges={d} order calls={d} orders={d} shipping calls={d} shipments={d}\n", .{
        shipment.checkout_id, shipment.tracking, store.payment_calls,  store.charges,
        store.order_calls,    store.orders,      store.shipping_calls, store.shipments,
    });
}
pub fn main(init: std.process.Init) !void {
    var store: Store = .{};
    const outcomes = checkout(fromValue(Cart{ .id = 42, .cents = 2500 }));
    try run(.{
        init.gpa,                    init.io,                   &store,
        Payments{ .store = &store }, Orders{ .store = &store }, Shipping{ .store = &store },
    }, .{pipe(outcomes, .{forEach(show)})});
}
