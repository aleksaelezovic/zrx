# Standalone example applications

Small, realistic applications live here as independent Zig projects. The
[examples above this directory](../../docs/README.md#executable-examples) remain
focused API demonstrations built by the library's root build.

## Applications

| App | Purpose | Validation |
|---|---|---|
| [Record processor](record-processor/README.md) | Bounded import validation, normalized output, diagnostics and summary | Run the project-local commands below from `record-processor/` |
| [Durable checkout](durable-checkout/README.md) | SQLite-backed local issuance, persisted idempotency and process-restart/crash simulations | Run the project-local commands below from `durable-checkout/`; requires Python 3 with `sqlite3` for tests |
| [HTTP jobs](http-jobs/README.md) | Bounded serial submission/status service, visible route/response branches and managed server lifetime | Run the project-local commands below from `http-jobs/` |

Each app has an independent Linux job in [CI](../../.github/workflows/validation.yml).
There is no shared app build: each project owns its build, dependencies and
tests. App dependencies do not enter the library.

## Project boundary

Each app owns its `build.zig`, `build.zig.zon`, `.zigversion`, `README.md`, source
and tests. Keep it independently buildable from its own directory:

```text
examples/apps/<app>/
  build.zig
  build.zig.zon
  .zigversion
  README.md
  src/
  tests/
```

- Pin the same exact Zig version as [zrx](../../.zigversion).
- Declare zrx as the local path dependency `../../..` in the app manifest,
  obtain it through `b.dependency("zrx", ...)`, and import its `zrx` module.
  Do not import library source files by relative path or create another executor.
- Keep SQLite and other application dependencies in the app's own manifest,
  pinned reproducibly. Document any external/system prerequisites explicitly.
  Library users must not acquire app dependencies by depending on zrx.
- App package paths should include only its build files, source, tests and
  documentation, not caches, outputs or fixture-generated databases.
- Runtime configuration, domain decisions and named compositions belong in the
  app. Reuse library operators; propose missing general primitives separately.
- Keep `main` lean. Tests should import the same app composition/domain modules,
  not copy their implementation.

## Local validation contract

Each app must document and support these commands from its own directory:

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

`test` runs unit and integration tests. `check` also checks formatting and runs
finite executable simulations. Verify real exit status, stdout/stderr, and
resulting files or database state, not merely successful compilation.

Simulations use temporary directories, finite inputs, loopback ephemeral ports,
explicit synchronization and bounded waits/processes. They must clean up children
and owned resources on failure. Default checks require no human input, public
services or timing sleeps. A fresh dependency download can require network access;
that is separate from a simulation contacting an external service.

Test failure paths as well as success. Durable-workflow apps must exercise restart
and defined crash points using the same persisted store, and distinguish local
transactions from external effects requiring idempotency or reconciliation.
Do not label a mock remote service as proof of real remote exactly-once behavior.

## Library checks and CI

The root build does not build these apps or resolve their dependencies. Run
project-local commands directly, or use the independent app CI jobs. Existing
ignore patterns cover nested `.zig-cache/` and `zig-out/` directories.

CI runs the four documented commands above for every app in its explicit job
matrix. Jobs run independently with fail-fast disabled, so one app failure does
not hide the others. The root job still owns the library's cross-target catalog;
app jobs execute native Linux simulations, not another target matrix.

The shared setup action reads the library's `.zigversion`, installs that exact
compiler without a persistent build cache, and checks the installed version.
Each app job also verifies that its own pin matches. The checkout app checks
Python's SQLite test prerequisite before running its app-local tests.

See the [local validation timings](../../docs/measurements/app-validation/README.md)
for fresh-job and warm-cache observations. They are not CI duration guarantees
or timing thresholds.
