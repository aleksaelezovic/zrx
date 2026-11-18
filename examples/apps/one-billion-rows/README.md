# One Billion Row Challenge

Compute each station's minimum, mean and maximum from the [original 1BRC
format](https://github.com/gunnarmorling/1brc). Both executables accept a file
or `-` for stdin and write the same sorted aggregate to stdout.

```sh
zig build -Doptimize=ReleaseFast
printf 'Zurich;2.0\nBasel;-0.1\nBasel;0.0\n' > measurements.txt
./zig-out/bin/one-billion-rows measurements.txt
./zig-out/bin/one-billion-rows-zig measurements.txt
# {Basel=-0.1/0.0/0.0, Zurich=2.0/2.0/2.0}
```

Both use the same parser and pre-sized hash table, with at most 10,000
stations and 100 UTF-8 bytes per name. A station name is copied only on first
sight. Temperatures are accumulated as integer tenths. The mean rounds to
the nearest tenth, with ties toward positive infinity. The final report uses
Java's UTF-16 sort order. Malformed input fails before the report is written.

The zrx app pushes inline lines into a terminal aggregation handler. The
standalone Zig app borrows each line until its update is complete. Both use
the same 64 KiB reader buffer and run on the calling task. The comparison
measures the full approach, including the cost of inline lines.

## Compare

On Linux or macOS with Python 3.11+:

```sh
python3 compare.py --rows 10000000 --runs 5
python3 compare.py measurements.txt --runs 5 \
  --reference 'java -Xmx512m -cp /absolute/path/to/classes dev.morling.onebrc.CalculateAverage_baseline'
```

The optional reference is the [original Java baseline](https://github.com/gunnarmorling/1brc/blob/main/src/main/java/dev/morling/onebrc/CalculateAverage_baseline.java),
compiled separately. The runner gives it a working directory containing
`measurements.txt`. Commands use the same file, run in mixed order after one
warm-up apiece, and must agree on the output checksum. It reports median
wall time and peak RSS for fresh processes, including runtime setup. The
generated workload repeats a seeded 100,000-row block. Supply an official
dataset for measurements on the official input distribution.

Run `zig build check` and `zig build test -Doptimize=ReleaseFast` for app checks.
