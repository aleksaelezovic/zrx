/// Explicit deterministic fault hooks, never probabilistic fault scheduling.
pub const Fault = enum {
    none,
    after_begin,
    after_insert,
    after_commit,
    rollback,
    output,
};
