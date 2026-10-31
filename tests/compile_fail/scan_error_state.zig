const zrx = @import("zrx");
const State = error{Broken}!u32;
fn invalid(state: State, _: u32) State {
    return state;
}
test {
    _ = zrx.scan(0, invalid);
}
