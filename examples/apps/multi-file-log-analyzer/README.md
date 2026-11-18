# Multi-file log analyzer

Scan two finite service logs, save errors to a JSONL file and print one
summary for both inputs. Each input has tab-separated fields
`timestamp_ms<TAB>level<TAB>service<TAB>latency_ms`. The level is `info`,
`warn` or `error`. Service names have 1 to 32 ASCII letters, digits,
underscores or dashes. Records are at most 128 bytes excluding LF.

```sh
zig build
printf '1\terror\tapi\t7\n3\twarn\tapi\t11\n' > left.tsv
printf '2\tinfo\tdb\t17\n4\terror\tdb\t19\n' > right.tsv
./zig-out/bin/multi-file-log-analyzer left.tsv right.tsv alerts.jsonl
```

Two tagged line sources feed `merge`. After parsing, a `branch` sends error
events through a 32-slot queue to the archive and all events through a
synchronous `fold` for the summary. Each event owns its service name. The
error file preserves order within each input. Cross-file order depends on
which source supplies a record first.

The summary has left, right and combined counters for records, warnings
and errors, plus the sum of latencies in milliseconds. The CLI reports it
after the alerts file is flushed and published. Malformed input or an output
failure returns exit **2**. An existing alerts path is preserved.

Run `zig build test`, `zig build test -Doptimize=ReleaseFast` and
`zig build check` from this directory.

The app tags the two readers with a small source wrapper at the merge
boundary. The tag then travels with each record through the pipeline.
