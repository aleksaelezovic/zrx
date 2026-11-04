# HTTP jobs

A small standalone zrx service: submit a bounded **sum job**, then retrieve its
recorded status/result. It computes synchronously and stores owned records in
application memory. There is no queue, background worker, persistence or auth.
Only one connection/request is active at a time. This is a loopback development
service, not a hardened public deployment.

## Build and check

Exactly Zig **0.17.0**, standard library only, with manifest-local zrx `../../..`.
From this directory:

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

`test` includes unit tests, the actual app graph over finite loopback clients,
and a spawned executable simulation checking status/headers/body, stdout,
stderr, exit status and listener cleanup. `check` also checks formatting and
builds/installs the executable. Scenarios have a 10-second watchdog, ephemeral
ports, explicit readiness/completion and joined cancellation/child cleanup.
No default command starts a live server, contacts public services, sleeps or
waits for human input. Run tests on a native hosted target; foreign execution is
not provided.

## Run (opt-in)

```sh
# serve PORT CONNECTIONS [MAX_JOBS [BODY_BYTES [MAX_VALUES]]]
./zig-out/bin/http-jobs serve 8080 2
```

The process flushes `ready http://127.0.0.1:8080` to stdout after listening. In
another terminal, make the two requests:

```sh
curl --http1.1 -i -H 'content-type: application/json' \
  --data-binary '{"label":"invoice-7","values":[20,-3,5]}' \
  http://127.0.0.1:8080/jobs
curl --http1.1 -i http://127.0.0.1:8080/jobs/1
```

After run returns and cleanup finishes it prints `stopped` and exits 0. Every **accepted connection** spends
the budget, including malformed/empty sessions; this is not a job count.
Port `0` selects an ephemeral port; count `0` acquires/releases without clients.
`live PORT [MAX_JOBS [BODY_BYTES [MAX_VALUES]]]` explicitly opts into ongoing
serving. The CLI has no signal-to-graceful-stop integration; process termination
loses memory. The reusable graph accepts zrx's stop event for graceful admission
stop/drain, exercised by tests. Configuration/run failures print one diagnostic
to stderr and exit 1.

## API and limits

Only `POST /jobs` and `GET /jobs/<id>` are supported. No query parameters,
trailing slashes, HEAD, listing or deletion.

- POST requires exactly one `content-type: application/json` (case insensitive,
  **no parameters**) and no `content-encoding`. Content-Length and chunked bodies
  use the real single-pass HTTP body reader.
- The JSON object has exactly `label` and `values`, no duplicate/unknown fields.
  Label is 1–32 ASCII letters/digits/`-`/`_`. Values are 1–`MAX_VALUES` JSON
  integers, each in `[-1000000, 1000000]`; quoted numbers/floats are rejected.
- Defaults: `MAX_JOBS=64` (allowed 1–1024), `BODY_BYTES=1024` (1–4096),
  `MAX_VALUES=16` (1–16). Startup allocates the fixed-capacity store; no eviction.
  A full store rejects submissions without changing recorded jobs.
- IDs are monotonic, process-local, starting at 1. GET requires canonical positive
  decimal u64 (no leading zero); no client-specified IDs or deduplication.
- POST returns **201**, `location: /jobs/1`; GET returns **200**. Both bodies are
  `{"id":1,"label":"invoice-7","status":"completed","result":22}` plus LF.
  Only completed records exist; there is no pending/running state.
- All app responses are JSON plus LF, `cache-control: no-store`, adapter-owned
  framing and connection close. Errors contain only `{"error":"code"}` plus LF:

| Status | Code / condition |
|---|---|
| 400 | `invalid_job`: invalid JSON/schema/domain values |
| 400 | `invalid_id`: malformed `/jobs/<id>` target |
| 400 | `invalid_body`: truncated body or malformed chunk framing/trailers |
| 404 | `not_found`: absent record or unknown route |
| 405 | `method_not_allowed`: recognized route, wrong method; includes `allow` |
| 413 | `body_too_large`: configured cumulative body bound exceeded |
| 415 | `expected_json`: missing/unsupported/duplicate content type or encoding |
| 503 | `store_full`: configured record capacity exhausted |

Headers are bounded at 4096 bytes/16 entries, targets at 128 bytes. Head timeout
is 2 seconds; the whole accepted session has a 5-second deadline. Responses are
bounded at 256 body bytes and 256 extra-header bytes/4 entries. Malformed or
unsupported HTTP heads may close without an app response, per the public adapter.

## Composition and ownership

`src/main.zig` supplies process capabilities, handles the returned error/OS exit,
and reports completion after successful run/cleanup. `app.execute` performs one
`run`; no argv parsing, store allocation or readiness coordinator runs outside
it. There are exactly three application resources:

- **Config:** converts native argv into scalar settings, then frees temporary
  conversion storage. `max_values` is a config field, not another rules service.
- **Store:** owns the bounded record array and releases it after users join.
- **Server:** owns the library HTTP owner, reports its acquired address and
  releases it after request users join. Borrowed readiness/stop events and the
  console file are constructor options, not additional resources. The default
  console is process stdout, which the app does not close.

`composition.zig` declares:

```text
httpRequests(Server) → route branch
  POST /jobs: readSubmission → validateSubmission → recordJob
  other methods /jobs: methodNotAllowedPost
  GET /jobs/<id>: parseJobId → lookupJob
  other methods /jobs/<id>: parseJobId → methodNotAllowedGet
  other targets: notFound
→ response branch
  created → 201; found → 200
  invalid job/id/body → 400; missing → 404; wrong method → 405
  body bound → 413; media policy → 415; store full → 503
  unhandled outcome → fail run
→ respondHttp
```

These are ordinary named handlers supplied to library operators, not custom
operators or another executor. `domain/commands.zig`, `domain/jobs.zig` and
`domain/routes.zig` hold pure configuration, job data/validation and routing
rules without live I/O capabilities or resource services. `store.zig` owns mutable
record storage; `requests.zig` contains body/store effects and correlated
envelopes; `response.zig` encodes the selected status/body. Method/target selection
and every response branch are visible in `composition.zig`, using `all`/`any`,
`httpMethod`, `httpTarget` and `httpTargetPrefix`. There is no imperative route
classifier or catch-all rendering switch. Raw targets deliberately preserve
query bytes to retain this API's strict target/identifier grammar. Only config is a
constructor-only recipe with a null finalizer. Server/store have explicit
ownership and cleanup. Pure validation receives values from config rather than
requesting a separate validation resource.

Client/domain failures stay **inside request-correlated envelopes**, not thrown
toward `Failure`/`recover` (which cannot recover the request). Typed submission,
validated-job and reply values keep the capability attached until rendering and
the response terminal; rejected inputs never reach store mutation. Unexpected I/O, allocation,
cancellation, source/acquisition or send failures fail the run with no invented
500, retry or rollback. Timeout/disconnection can occur after a record was
stored; successful flush does not prove client receipt. Retrying POST can create
duplicates. Even the in-memory mutation and HTTP delivery are not atomic.

JSON arenas are freed during validation; stored jobs copy their label/values.
Responses use the library's bounded `jsonResponse` encoder; app code supplies
ordinary payload data, status and cache/location headers. Header access uses
`uniqueHeader`/`headerValues`; body handling switches only on stable
`HttpBodyTooLarge`/`HttpInvalidBody`, preserving unexpected failures.
Console output uses a temporary standard writer during server acquisition;
it remains separate from request-scoped HTTP response transport. No request, body
reader, response token or borrowed slice is retained after request completion.
Readiness reporting is fallible resource acquisition work, including for
zero-connection runs. A later acquisition failure can follow this report; it
means listening, not guaranteed subsequent activation. If the acquisition report
fails, the server constructor cleans up its partial acquisition. Request users
stop/join before listener/store release. Only then does main report `stopped`;
failure suppresses that completion message. There is no final job count because
the managed store has already been destroyed. Tests verify the listener is
closed when the completion line arrives, not merely after process exit.
There are no exit-status cells, fan-out, retention or nested runs.

## Reusable library boundary

| Capability | zrx contract versus application policy |
|---|---|
| Config/server/store ownership | Three normal resource recipes. Config owns temporary argv conversion; server wraps the library HTTP owner and borrows process output. |
| Managed HTTP input | `HttpServer` owns transport; `httpRequests(ServerRole)` borrows it, sharing existing runtime/completion machinery. |
| Readiness/completion reporting | An app-specific resource adds readiness reporting; main reports completion after checking run's outcome. No generic hook API. |
| Header access, protocol failures, JSON encoding | Library mechanisms. Duplicate/media-type decisions, HTTP statuses and correlated domain rejections remain app policy. |
| Request predicates and boolean composition | Library `httpMethod`/target/path predicates and short-circuit `all`/`any`; the route table and HTTP outcome selection stay visible in the app pipeline. |

Both commands configure the same server pipe. No arbitrary producer-child
`flatMap`, conditional graph selection, help-command listener suppression or
second CLI application is needed for this service.
