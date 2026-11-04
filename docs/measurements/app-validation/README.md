# Local standalone-app validation wall times

[Validation scope](../../validation.md) · [App conventions](../../../examples/apps/README.md)

These are **one local observation per command/cache state**, not runtime
benchmarks, timing thresholds or predictions for GitHub runners.
All 24 measured commands exited successfully. [Raw observations](results.csv)
retain the unrounded elapsed seconds and exit status.

## Environment and source

- Date: 2026-11-04, 13:54:51–13:59:51 UTC.
- Application/library revision: `87f4d232adde760acf24b1813b2432677adcb2da`.
  Working-tree changes at collection affected CI configuration, not app/library code.
- Zig **0.17.0**, default **stage2_llvm** backend verified for both Debug and
  ReleaseFast; no forced backend or extra build flags.
- Native target: `aarch64-macos.27.0.1...27.0.1-none`.
- Apple M1 Pro, 10 logical CPUs, 16 GiB RAM, macOS 27.0.1.
- Python 3.14.0; its independent test-observer SQLite was 3.50.4.
  The checkout application separately compiled its pinned SQLite 3.54.1.
- Source SHA-256:
  `aa1847db38ea75d59ec8a73d00685728c783704a2320f05a087e39de4107a97a`.
  Hash sorted repository `.zig`, `.zon`, `.py`, and `.zigversion` files by
  appending each relative path, NUL, file bytes, NUL to one SHA-256 stream.

## Method and reproduction

1. Copy tracked/nonignored working source into a new temporary project tree,
   preserving relative package paths. Do not copy generated caches, `zig-pkg/`
   or installed output.
2. For each app, select previously nonexistent per-app directories with
   `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR`. Keep the same directories
   through that app's two passes; do not share compilation caches between apps.
3. In each app directory, time these exact commands in this order:

   ```sh
   zig build
   zig build test
   zig build test -Doptimize=ReleaseFast
   zig build check
   ```

4. Repeat the four commands immediately with the same caches for the warm pass.
   App order was record processor, durable checkout, HTTP jobs. Run sequentially,
   not alongside other builds or tests.
5. Measure each subprocess with Python's monotonic `time.perf_counter`, from
   launch through exit, capturing stdout/stderr to a per-command log. Record exit
   codes; fail on any error rather than retrying failed trials.

Source copying, metadata/probe commands and workflow linting are excluded.
The fresh checkout build **includes dependency downloading**; source and
compilation caches started empty. OS caches were not flushed. This agent
launched no competing build/test work during collection, but ambient host load
was uncontrolled. There was no warmup or statistical sampling.

## Results

Seconds, rounded for display. The total is the sum of the four command wall times.

| App | Fresh build | Debug tests | ReleaseFast tests | Final check | Fresh-job total | Warm total |
|---|---:|---:|---:|---:|---:|---:|
| Record processor | 58.34 | 3.59 | 19.62 | 0.24 | **81.79** | 0.89 |
| Durable checkout | 89.41 | 3.16 | 23.89 | 1.30 | **117.77** | 3.68 |
| HTTP jobs | 60.15 | 7.68 | 27.21 | 0.24 | **95.28** | 0.74 |

The three fresh-job sequences took **294.84 seconds combined**, sequentially.
The corresponding warm sequences took **5.31 seconds combined**.

“Fresh job” does not mean every command starts cold: the first build warms the
cache used by the following three commands, exactly as the CI sequence does.
Zig can cache successful test results, so the warm figures and final check
are **not measurements of simulation execution time alone**. The checkout's
Python process/database simulations deliberately rerun; its run step is marked
with side effects.

CI runs the apps on separate Linux runners in parallel with the library job.
Runner hardware, setup/download time and scheduling differ; these local totals
are neither additive CI wall time nor CI performance guarantees.
