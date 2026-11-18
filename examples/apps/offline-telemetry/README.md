# Offline telemetry

Replay two cold-storage sensor feeds. Alerts stream to stdout and routine
windows go to a JSONL archive. Input is
`timestamp_ms,temperature_millidegrees_C` with no header and at most 64 bytes
per line excluding LF.

```sh
zig build
printf '1,3500\n2,8200\n' > north.csv
printf '3,4900\n4,5000\n' > south.csv
./zig-out/bin/offline-telemetry north.csv south.csv windows.jsonl
```

Each feed runs its own program in a `system`. Its `route` sends readings
outside 0–8 °C to an alert handler and routine readings to its own
`batchWithin(8, .fromMilliseconds(200))`. A window reports its count, minimum,
maximum, sum, and the first and last timestamps in arrival order. The timeout
uses processing time. Recorded timestamps stay in the output for analysis.
A partial window also flushes at EOF.

Each destination has its own mutex-protected writer. Alerts are flushed to
stdout as they are processed. Windows are flushed to the archive writer and
the final file is published after both feeds finish. Cross-feed record order
and exact window groupings can vary with scheduling and input pace. An
existing archive is preserved. On malformed input or a failed run the CLI
returns exit **2** without publishing a new archive. Alerts already written
to stdout remain visible.

The injected-I/O test holds a source open until its partial window is written.
The source cannot reach EOF before that write.

Run `zig build test`, `zig build test -Doptimize=ReleaseFast` and
`zig build check` from this directory.
