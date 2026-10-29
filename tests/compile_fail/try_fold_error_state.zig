const zrx = @import("zrx");
const tryFold = zrx.tryFold;

const State = error{Failed}!u32;
fn invalid(state: State, _: u32) error{Outer}!State {
    return state;
}

test {
    _ = tryFold(0, invalid);
}
