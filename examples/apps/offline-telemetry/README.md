# Offline telemetry

Replay two cold-storage sensor feeds into one JSONL event file. Input is
`timestamp_ms,temperature_millidegrees_C` with no header and at most 64 bytes
per line excluding LF.

```sh
zig build
printf '1,3500\n2,8200\n' > north.csv
printf '3,4900\n4,5000\n' > south.csv
./zig-out/bin/offline-telemetry north.csv south.csv events.jsonl
```

Each feed runs its own program in a `system`. Its `route` sends readings
outside 0–8 °C to an alert handler and routine readings to its own
`batchWithin(8, .fromMilliseconds(200))`. A window reports its count, minimum,
maximum, sum, and the first and last timestamps in arrival order. The timeout
uses processing time. Recorded timestamps stay in the output for analysis.
A partial window also flushes at EOF.

The feeds share one mutex-protected writer. Each emitted alert or window is
flushed into the output file. The combined record order and exact window
groupings can vary with scheduling and input pace. The CLI publishes the file
after both feeds finish and preserves any existing destination. A malformed
line or failed run returns exit **2** without publishing a new file.

The injected-I/O test holds a source open until its partial window is written.
The source cannot reach EOF before that write.

Run `zig build test`, `zig build test -Doptimize=ReleaseFast` and
`zig build check` from this directory.
