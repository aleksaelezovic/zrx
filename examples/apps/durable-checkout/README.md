# Durable local checkout

A standalone Zig 0.17.0 application using zrx's public package module. One finite
CLI invocation issues one **local** checkout receipt in SQLite. There is no
payment, shipping call, server, workflow engine, or background retry loop.
The small [`../../checkout.zig`](../../checkout.zig) remains an in-memory API demo.

## Build and use

Run from this directory. Prerequisites: exactly Zig 0.17.0, a supported native C
toolchain environment for Zig/libc, and Python 3 with its standard `sqlite3`
module (SQLite >= 3.37, for STRICT tables) for tests. No system SQLite linkage,
SQLite executable, pip packages, or package installation is required. The first
build downloads public SQLite source.

On the validation host, standalone `zig fetch URL` produced a malformed global
cache archive with a nested directory despite its stripped-root hash. Normal
build fetching succeeded with a clean global cache. If that host cache causes a
hash/layout mismatch, use this exact validated bootstrap from the app directory:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/fresh-global" zig build --fetch
```

This was tested with no existing app-local `zig-pkg/` and a previously absent
`fresh-global` directory, followed by ordinary `zig build`. It downloads from
the manifest using the correct upstream hash; it does not modify/delete the
external global cache. Do not transfer generated `zig-pkg/` or cache contents
between worktrees: the manifest and this clean fetch suffice.

```sh
zig build
./zig-out/bin/durable-checkout /tmp/my-checkout.db key-42 cart-42 2500
# issued checkout=1 cart=cart-42 cents=2500
./zig-out/bin/durable-checkout /tmp/my-checkout.db key-42 cart-42 2500
# reused checkout=1 cart=cart-42 cents=2500 (a new process, same persisted receipt)
./zig-out/bin/durable-checkout /tmp/my-checkout.db key-42 cart-42 2501
# stderr: error: Conflict; exit 3; database unchanged
./zig-out/bin/durable-checkout --help
# usage on stdout; no database opened or created
```

Choose a new database path for this demonstration; the application never deletes
old receipts. Key and cart are case-sensitive ASCII `[A-Za-z0-9_-]`, 1–64 bytes.
Input identity is the complete `(cart, numeric cents)` pair, not a hash or the
raw spelling of the amount. Cents is a positive `u32`; leading zeroes are accepted.
Different keys may issue separate receipts for identical inputs. A changed cart
or amount for an existing key conflicts, without replacing the original result.
An ID is meaningful only within its database; this is not a global order ID.

Exit 0 means the receipt was committed/reused and stdout flushed, or help flushed
successfully. Exit 2 is invalid CLI input after usage delivery; exit 3 is a
key/input conflict; exit 1 is another failure (including a failed usage write),
with a best-effort named error on stderr. No success receipt is printed on a storage
failure. Output can fail or be lost **after commit**: absence of acknowledgement
is not evidence that issuance failed. Repeat the same key and input to resolve it.
The caller must preserve the key across retries and process restarts.

## Local transaction and crash contract

[`src/composition.zig`](src/composition.zig) exposes one cold command declaration:

```text
fromService(Command) -> branch
  help:     write help + flush
  invalid:  write usage + flush -> InvalidArguments
  checkout: request -> issue transaction -> owned receipt text -> writeLine + flush
```

[`src/app.zig`](src/app.zig) supplies `arguments(std.process.Args)`, the typed
command recipe, conditional SQLite storage, and nominal console/diagnostic
writer recipes, then invokes `run` once. The constructor-only command recipe
uses `resource(..., null)` and borrows the managed argument view through the run.
[`src/domain.zig`](src/domain.zig) is the public checkout interface, exposing
`Request`, `Result`, `Command`, `Store` and their supporting configuration/types.
Application wiring imports that facade; implementation modules import specific
siblings directly. The checkout-specific implementations live under `src/domain/`:
[`commands.zig`](src/domain/commands.zig) owns pure CLI parsing policy,
[`request.zig`](src/domain/request.zig) holds input identity/validation, and
[`result.zig`](src/domain/result.zig) holds receipt values and formatting.
Invalid usage is data, not a failed constructor. All command cases terminate
independently; there is no completion/status side channel or nested execution.

[`src/resources.zig`](src/resources.zig) gates database acquisition by immutable
command before activation: help/invalid commands own no connection and cannot
create a database. Checkout acquisition opens/configures SQLite; release closes
it after users join. The console/diagnostic roles derive zrx's standard managed
`Writer` ownership; effects explicitly flush, while release never flushes failed
work or closes process stdio. Domain receipt formatting produces owned bounded
text with `Text.fromFormat`. `main` only supplies capabilities, propagates the
pipeline outcome into OS exit policy, and reports unexpected errors best-effort.
The caller keeps supplied process argument referents stable through the run.
No reader, expansion operator, or per-statement effects are needed for this
singleton transaction.

[`src/domain/store.zig`](src/domain/store.zig) uses `BEGIN IMMEDIATE` to serialize lookup/insert,
a unique key, exact identity comparison, and an immutable stored integer receipt.
The key, identity, and result commit together in one row. Successful duplicate
lookups return that row's ID, not a fresh result. Schema initialization is a
separate local transaction and may leave an empty initialized database on failure.
Application ID and schema version 1 reject foreign/unversioned nonempty stores
and unsupported versions; migrations and tamper detection are not implemented.
Only this app should write the schema/data. Do not delete rows, copy a live
database without SQLite's backup protocol, or separate it from a live journal.

The app requests and verifies rollback-journal `DELETE` mode and synchronous
`FULL`. A process crash before commit leaves no issuance; a process crash after
commit retains the receipt even before stdout. Normal pre-commit errors attempt
rollback. A commit/storage error can be ambiguous; reopen and resubmit the same
key/input rather than assuming failure. SQLite locking has a bounded 250 ms busy
timeout and returns `Busy`; the app never blindly retries. SQLite's synchronous
C calls are not zrx-cancelable, and this connection belongs to one serial root.
Use a local filesystem with working SQLite locks/sync; network filesystems,
multiple machines, disk corruption, and adversarial writers are outside scope.

These are **process-crash tests**, not a power-loss proof. SQLite's durability
also relies on its VFS, OS, filesystem, and storage honoring locking and sync.
There is no tested hardware/power-loss guarantee or protection against restoring
an old database backup. Never interpret this local issuance as an exactly-once
external payment or shipment. Later remote delivery needs a separate protocol:
destination idempotency/receipt lookup and reconciliation for ambiguous outcomes.
An outbox or a repeatable zrx run alone would not close that remote-effect window.

## Dependency decision

The app manifest pins the official **SQLite 3.54.1** amalgamation archive by URL
and Zig content hash. The build compiles `sqlite3.c` with libc, thread safety,
double-quoted string literals disabled, and extension loading omitted. SQLite's
deliverable code is [public domain](https://www.sqlite.org/copyright.html);
the archive's source header contains its dedication. No third-party Zig binding
or system SQLite ABI/version is selected. [`build.zig`](build.zig) uses Zig's
`addTranslateC` to generate the private `sqlite_c` module from the same pinned
`sqlite3.h`, with the same C flags used for compilation. No handwritten SQLite
ABI declarations/constants or checked-in generated bindings are needed.
The application-owned storage operation still owns transactions, error policy,
statement lifetimes, and failed-open cleanup. Bound string referents remain
stable through statement finalization. Crash hooks use the standard `std.c._Exit`.
[`tests/sqlite.zig`](tests/sqlite.zig) checks the generated header against the
linked engine version and verifies the configured SQLite compile options.
Python's SQLite is only an independent test observer/lock holder.
This app-local dependency does not change zrx's library manifest or build.

## Validation

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

`test` runs Zig domain/parser/composition tests and
[`tests/integration.py`](tests/integration.py), which starts the real executable
in new processes using temporary directories. `check` adds Zig formatting checks
to the same unit/integration/finite-simulation path. Unit tests exercise the
production command declaration with injected arguments and standard writer roles,
including writes that buffer successfully but fail during the explicit flush.
Flush errors take precedence over successful command completion or expected
usage errors, and cannot undo committed receipts. Private storage tests cover
row-result error classification. Tests assert exit status,
stdout, stderr, stored rows, and database integrity for issuance, duplicate,
both input conflicts, help/usage without storage, invalid input, unavailable
storage, bounded lock contention,
unsupported databases, rollback, and post-commit output failure.

The explicit `--fault POINT` option is **for fault testing only**:

| Point | Behavior | Next process |
| --- | --- | --- |
| `after-begin` | `_Exit(85)` with open transaction | No issuance |
| `after-insert` | Flush dirty cache pages, `_Exit(86)` before commit, no cleanup | On-disk rollback journal recovered |
| `after-commit` | `_Exit(87)` before output, no cleanup | Same receipt reused |
| `rollback` | Return `InjectedFailure` after insert | Rollback, no issuance |
| `output` | Inject terminal `OutputUnavailable` after commit | Same receipt reused |

`_Exit` bypasses Zig defers and C exit handlers. The app itself is the first
database opener after each crash, before Python inspects recovery results.
The after-insert hook uses SQLite's public `sqlite3_db_cacheflush` to spill dirty
pages without committing; the test confirms that a journal survives termination.
Subprocesses have closed stdin, captured output, and five-second timeouts that
kill/wait on failure; no human waits, public services, or timing sleeps schedule
faults. The lock test holds a transaction explicitly while the child runs.
The suite does not simulate arbitrary instruction-level death, commit-time
power loss, disk-full/partial-write faults, or remote services.
Root library checks are separate and are not run by this app.

Review this local issuance milestone before adding remote delivery or migrations.
