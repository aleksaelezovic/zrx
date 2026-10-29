const zrx = @import("zrx");
const fold = zrx.fold;

const State = error{Failed}!u32;
fn invalid(state: State, _: u32) State {
    return state;
}

test {
    _ = fold(0, invalid);
}
