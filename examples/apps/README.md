# Standalone example applications

Small, realistic applications live here as independent Zig projects. The
[examples above this directory](../../docs/README.md#executable-examples) remain
focused API demonstrations built by the library's root build.

This directory currently contains conventions only: no app implementation,
third-party dependency, app runner or CI integration has been added.

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

## Library checks and future CI

The root build does not build these apps or resolve their dependencies. Keep app
validation opt-in until each app exists and is reviewed. Existing ignore patterns
already cover nested `.zig-cache/` and `zig-out/` directories.

Future CI should call each app's documented commands, rather than implement a
second simulation flow or duplicate the library's cross-target catalog. Add app
discovery/catalog tooling only when there are real projects to run.
