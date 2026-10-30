# I/O adapters

**Current:** [`readFrom`](readFrom.zig) borrows a standard `std.Io.Queue(T)`.
It is interoperability glue, not a replacement queue or I/O framework.

**Future feature, not implemented:** small terminal, TCP, and filesystem adapters
that connect standard Zig I/O to zrx stream declarations and explicit terminal
effects. Design each adapter with its own item type, ordering, EOF/error behavior,
buffering, cancellation, and resource ownership before implementation.

- Reuse standard readers/writers, clients, files, and `std.Io`; do not build a
  parallel I/O stack, scheduler, or universal service context.
- Declarations must not open resources or start work. Activation belongs to
  `run`; producers can use their call-scoped emitter's allocator/Io.
- Pass domain capabilities explicitly. State whether handles are borrowed or
  owned, join work before releasing it, and keep buffered item referents valid.
- Prefer existing `Stream(T).fromProducerWith` and terminal operators where
  sufficient; add only adapters that remove repeated, demonstrated glue.

See the [execution guide](../../docs/execution.md) and
[stream example](../../examples/streams.zig) for the implemented building blocks.
