# HTTP benchmark

Two HTTP/1.1 servers with the same `std.Io` sockets, `std.http.Server`,
request limits and handlers. The standalone Zig binary dispatches with
conditionals. The zrx binary builds one synchronous request pipeline per
connection using `fromProducer`, `route`, and `forEach`.

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/http-bench serve 8080 8
# In a separate terminal:
curl 'http://127.0.0.1:8080/baseline11?a=13&b=42'  # 55
curl -d 20 'http://127.0.0.1:8080/baseline11?a=13&b=42'  # 75
curl 'http://127.0.0.1:8080/json'  # {"message":"Hello, World!"}
```

`http-bench-zig` accepts the same commands. Both bind only to loopback.
Each worker serves one connection at a time and reuses it for keep-alive.
Request heads have an 8 KiB reader buffer and POST sums accept at most
32 body bytes. The borrowed request stays within its synchronous handler.
An app-local adapter connects the HTTP request to the pipeline.

`/baseline11` implements the integer sum workload from the [HttpArena
baseline profile](https://http-arena.com/docs/test-profiles/h1/baseline/implementation/),
including fixed-length and chunked POST bodies. `/json` serializes a small
object per request. These local measurements cover individual workloads at
the selected connection count. HttpArena's full profile uses its own harness
and a mixed request stream.

## Compare

With Python 3 and the `hey` load generator installed on Linux or macOS:

```sh
zig build -Doptimize=ReleaseFast
python3 compare.py --workload baseline --runs 5
python3 compare.py --workload post --runs 5
python3 compare.py --workload json --runs 5
```

Each run starts a fresh process, checks exact responses over a reused TCP
connection, warms the server and checks the count of successful responses.
The runner reports request throughput, p99 latency and peak process RSS.
Both Zig servers use the same connection and worker counts. The default
leaves spare workers for short overlaps between client connections. An idle
keep-alive connection still occupies a worker. An optional reference
server can be supplied with `--reference` if it implements the same endpoint
and accepts `serve PORT WORKERS`, starts on the requested loopback port
(`0` chooses a free port), and prints the port on stdout when ready.

`zig build check` and `zig build test -Doptimize=ReleaseFast` exercise
the same HTTP fixtures through injected readers and writers and through
both real binaries in `replay REQUEST_FILE` mode.
