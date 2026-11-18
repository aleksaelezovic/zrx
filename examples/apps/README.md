# Standalone example applications

Small, realistic applications live here as independent Zig projects. The
[examples one level up](..) stay focused API demonstrations built by the
library's root build.

| App | Purpose |
|---|---|
| [Record processor](record-processor/README.md) | Bounded import validation, normalized output, diagnostics and a summary |
| [Multi file log analyzer](multi-file-log-analyzer/README.md) | Finite log merge, queued fan-out and aggregate reporting |

## Project boundary

Each app owns its `build.zig`, `build.zig.zon`, `.zigversion`, `README.md`,
source and tests, and builds from its own directory:

- Pin the same exact Zig version as [zrx](../../.zigversion).
- Depend on zrx by the local path `../../..` through `b.dependency("zrx", ...)`
  and import its `zrx` module. Do not import library source files by path.
- App dependencies stay in the app's manifest; depending on zrx must not pull
  them in.
- Domain decisions and named pipes belong in the app. Reuse library operators;
  when the library lacks something general, work around it in the app and
  record it in the app's README rather than changing the library in passing.
- Keep `main` lean. Tests import the app's own composition and domain modules.

## Checks

Every app supports, from its own directory:

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

`test` runs unit tests, the production composition with injected I/O, and the
real executable on finite inputs with its exit status and output asserted.
Executable runs use temporary directories, bounded waits and no network, and
clean up their child on failure. `check` adds formatting.

The root build does not build these apps. Each has its own job in
[CI](../../.github/workflows/validation.yml).
