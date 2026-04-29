# Async Handlers — Development Context

**Purpose:** This document is the single entry point for any future work on the async handler
feature. Read this first. It tells you what was built, why, who built it, what state
everything is in, and what is still open. Use the linked documents for details.

---

## 1. Roles

| Role | Who |
|---|---|
| Architect / Owner | g41797 |
| Code implementation | Claude Code (claude-sonnet-4-6) and Gemini CLI |

---

## 2. Repository Structure

### Parent repo
`github.com/g41797/matryoshka-http-template` — Odin HTTP service template using the
Matryoshka pipeline framework.

### odin-http fork (submodule)
`deps/odin-http` is a git submodule pointing to `https://github.com/g41797/odin-http`.
That repo is a fork of `https://github.com/laytan/odin-http` (the upstream odin-http library).

All async handler code lives in `deps/odin-http`. It is NOT in the upstream repo.

### Collections (Odin build system)
Since Plan v0.6, imports use Odin collections:
- `import http "http:."` → `deps/odin-http`
- `import "matryoshka:."` → `deps/matryoshka`

Collection flags: `-collection:http=$(pwd)/deps/odin-http -collection:matryoshka=$(pwd)/deps/matryoshka`
(set in `kitchen/build_and_test.sh`, `kitchen/build_and_test_debug.sh`, `.github/workflows/ci.yml`,
`.vscode/tasks.json`).

---

## 3. What Was Added to deps/odin-http

Three categories of change relative to upstream `laytan/odin-http`:

### 3.1 Async Handler Functionality (core feature)

New files:
- `resume.odin` — public API: `mark_async`, `cancel_async`, `resume`

Modified files:
- `response.odin` — added `node: list.Node` (first field, required by MPSC), `async_handler: ^Handler`, `async_state: rawptr`; `#assert` on field offset; disconnect guard in `response_send`
- `server.odin` — added `Connection.owning_thread`; added `Server_Thread.resume_queue` and `async_pending`; MPSC init in `_server_thread_init`; resume loop after `nbio.tick()`; shutdown exit condition checks `async_pending == 0`

### 3.2 MPSC Package (internal dependency)

Location: `internal/mpsc/` (three files: `queue.odin`, `queue_test.odin`, `edge_test.odin`)

This is a lock-free Vyukov MPSC queue, generic over any struct with a `node: list.Node` field.
It has zero dependency on odin-http or nbio — pure Odin.

**Status:** Bundled as `internal/mpsc` — not part of the public API.
**Future:** May be submitted to Odin core as `core:container/mpsc` or `core:sync/mpsc`. If
accepted, the odin-http import would switch from `internal/mpsc` to `core:mpsc` and the copy
would be dropped. Treat it as an external library in disguise.

### 3.3 Misc Fixes (non-async, found during stress testing)

- `server.odin`: shutdown loop improvements (1ms `nbio.tick` instead of blocking tick, only
  close `.New`/`.Idle`/`.Pending` connections — NOT `.Active`), `conn_handle_req` returns early
  when `server.closing` to prevent new recv registration during shutdown
- `response.odin`: `log.errorf` → `log.warnf` in `on_response_sent` (Odin test framework treats
  `errorf` as test failure; disconnect during async is expected, not an error)
- `server.odin`: `context.temp_allocator` save/restore in resume loop (root fix for allocator
  poisoning that manifested as intermittent crashes under stress)

**Note on two redundant fixes (see §19.2–19.3 in `async-handlers.md`):** The changes to
`scanner.odin` (temp_allocator before token callback) and `server.odin` `on_headers_end`
(temp_allocator before handler call) were redundant and have been **reverted** in Plan v0.8 to keep the
upstream diff minimal.

---

## 4. Tests

`deps/odin-http` has **no tests** (matching upstream convention).

All tests live in the parent repo:

| Path | Type | Tests |
|---|---|---|
| `tests/unit/` | Unit tests | pipeline, handlers, http_cs packages |
| `tests/functional/` | Functional (calls examples) | echo, pipeline, async (8 tests) |
| `tests/functional/async/` | Async-specific | direct, body, split, shutdown, stress, disconnect, misuse |
| `deps/odin-http/examples/async/` | Example servers (in odin-http fork) | `with_body_async.odin`, `without_body_async.odin`, `ping_pong.odin` |

Run all: `bash kitchen/build_and_test.sh` (5 optimization levels) or
`bash kitchen/build_and_test_debug.sh` (debug only, faster).

**Important:** Always set `ODIN_TEST_THREADS=1` (already in the build scripts). Running multiple
test binaries in parallel exhausts file descriptors and io_uring entries.

---

## 5. Development History

All implementation plans and stage logs are in `kitchen/docs/addendums/impl_status.md`.

| Plan | What | Result |
|---|---|---|
| v0.1 | Base_Server refactor + initial async tests | All stages PASS |
| v0.2 | API normalization + semaphore-based wait | All stages PASS |
| v0.3 | Post_Clients (batch HTTP client for tests) | All stages PASS |
| v0.4 | Post_Clients verdict improvements | All stages PASS |
| v0.5 | Upgrade async tests to N>1 concurrent clients | All stages PASS |
| v0.6 | Odin Collections conversion | All stages PASS |
| v0.7 | Consolidate async examples into deps/odin-http fork; tests embed server infrastructure | All stages PASS |
| v0.8 | PR Prep: Revert redundant fixes, add documentation, generate PR report | All stages PASS |
| v0.9 | Rewrite doc.odin, example comments, pr_report.md from source docs | All stages PASS |

---

## 6. Known Issues and Their Resolutions

### 6.1 macOS SIGBUS (exit code 138) in test_direct_async

**Root cause:** An earlier fix ("Fix 3") force-closed `.Active` connections in the shutdown
loop. On macOS, after `posix.close(fd)`, kqueue can still deliver already-queued EVFILT_READ
events. If `free(c)` happened before the recv callback fired, `scanner_on_read` accessed a
freed connection → SIGBUS.

**Resolution:** Reverted Fix 3. `.Active` connections are NOT force-closed. Instead, the
`conn_handle_req` guard (`if atomic_load(&c.server.closing) { return }`) prevents new recv
registrations during shutdown. Connections drain naturally: `on_response_sent` →
`clean_request_loop` → `conn_handle_req` returns early → no new recv → connection becomes
`.Idle` → shutdown loop closes it safely.

### 6.2 Windows memory leaks during shutdown

Same `conn_handle_req` guard also fixes this — `.Active` connections drain without starting
a new recv cycle, so they transition to `.Idle` and get closed cleanly.

### 6.3 Shutdown spin loop (verbose debug output)

`_server_thread_shutdown` uses `nbio.tick(1ms)`. With `Conn_Close_Delay = 500ms`, the loop
spins ~500 times per connection while waiting for the close timer. This produces hundreds of
"shutdown: connection X is closing" debug log lines. This is expected behavior, not a bug.

### 6.4 Allocator poisoning under stress

The initial resume loop set `context.temp_allocator` but did not restore it afterward. After
the resume handler returned, subsequent event-loop iterations inherited a stale arena. Fixed
by save/restore (`old_temp` pattern) in the resume loop.

---

## 7. Key Design Decisions

### Why mark_async / cancel_async / resume (not a simpler API)

`mark_async` must happen BEFORE background work starts (increments `async_pending`).
`resume` must be called exactly once (MPSC push + wake_up). `cancel_async` is needed for
rollback when background work fails to start — omitting it leaves `async_pending` permanently
incremented and graceful shutdown hangs forever.

### Why MPSC (not a channel/mutex)

The resume queue is written by many background threads (producers) and read by one io thread
(consumer). MPSC is the exactly correct primitive. `nbio.wake_up` is already used by
`server_shutdown` — no new OS primitive needed.

### Why async_handler field (middleware fix)

The original resume loop always restarted from `server.handler` (the chain head). Any
middleware before the async handler would execute twice — double logging, double rate-limiting,
double side-effects. Storing `async_handler` at `mark_async` time lets the resume loop call
the exact handler that went async. See §6.1 in `async-handlers.md`.

### Why intrusive MPSC (node as first field of Response)

No extra allocation per enqueued response. The `node: list.Node` field is embedded directly
in `Response`. The `#assert(offset_of(Response, node) == 0)` is a compile-time guard that
fires if `node` is ever moved from the first position.

---

## 8. What Is NOT Done

### 8.1 odin doc comments for async code

The upstream `laytan/odin-http` uses `odin doc` generation. In Plan v0.8, documentation
was added for the async examples (`deps/odin-http/examples/async/doc.odin`) and the
core async patterns. Documentation for `internal/mpsc/` remains internal.

### 8.2 Upstream PR to laytan/odin-http

The async changes have not been proposed upstream. Before doing so:
- [x] Revert the two redundant allocator fixes (§3.3, §19.2–19.3 in `async-handlers.md`)
- [x] Add odin doc comments (§8.1)
- [ ] Decide what to do with `internal/mpsc` (bundle vs. submit to core separately)

### 8.3 Production pattern not demonstrated

The example servers use `thread.create` per request. This is documented as a learning pattern
only, not for production. A Matryoshka pipeline integration (the actual production target) has
not been implemented yet. See `async-handlers-for-advanced.md` §3–§4.

---

## 9. Document Map

| Document | What it covers |
|---|---|
| `async-handlers.md` | Full design: requirements, architecture, API reference, MPSC, edge cases, code skeletons, §18 stress findings, §19 implementation review |
| `async-handlers-for-dummies.md` | Beginner guide: how async works, simple example, hard rules |
| `async-handlers-for-advanced.md` | Production pattern: pipeline integration, allocator strategy, middleware awareness |
| `http-handler-explain.md` | How synchronous handlers work (baseline, pre-async) |
| `handler_with_body.md` | Sync handler with request body (baseline) |
| `impl_plan.md` | Latest implementation plan (v0.7: PR Prep — examples to odin-http fork) |
| `impl_status.md` | Full stage log for all plans v0.1–v0.6 |
| `base_server.md` | Base_Server / Base_Router API used in examples and tests |
| `post_clients_design.md` | Post_Clients batch HTTP client design (used in tests) |

---

## 10. Quick-Start for Future Work

1. Read this document.
2. Read the design doc section relevant to the work:
   - New to async? → `async-handlers-for-dummies.md`
   - Internals / edge cases? → `async-handlers.md`
   - Production integration? → `async-handlers-for-advanced.md`
3. The odin-http fork remote is `https://github.com/g41797/odin-http`.
   Work in `deps/odin-http`.
   Former remote repository is https://github.com/laytan/odin-http .
4. Run `bash kitchen/build_and_test_debug.sh` after changes.
5. Run `bash kitchen/build_and_test.sh` before committing.
6. MUST RULE - Except status, all git operations disabled. Show to user the list of commands to run — do not run by yourself.
