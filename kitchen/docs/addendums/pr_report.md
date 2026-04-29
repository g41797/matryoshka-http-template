# PR: Async Handler Support for odin-http

## 1. Summary

This PR adds async handler support to odin-http via a "split handler" pattern: a single
handler proc handles both the initial request (Part 1) and the deferred response after
background work completes (Part 2), distinguished by `res.async_state`. Resume signals
are delivered through a per-IO-thread lock-free MPSC queue; the IO thread is woken via
`nbio.wake_up`, the same primitive already used by `server_shutdown`. Three examples
demonstrate the three practical variants. Three non-async fixes to `server.odin` and
`response.odin` are included — found during stress testing. The MPSC queue is bundled
as `internal/mpsc` (pure Odin, no odin-http or nbio dependency) and may be proposed to
Odin core separately.

---

## 2. The Problem

Any handler that does slow work — a database call, a file read, an external API, heavy
computation — blocks the IO thread for the full duration of that work. With a small
fixed thread pool (one thread per CPU core by default), this caps throughput to
`thread_count` concurrent blocking requests regardless of how much backend capacity
exists.

**Goal:** handlers and body callbacks return immediately to the event loop. When backend
work completes, the same handler is re-invoked on the IO thread with the result —
without changing the existing `Handler_Proc` or `Body_Callback` signatures.

---

## 3. The Split Handler Pattern

One handler proc, two invocations. `res.async_state` is the guard:

```odin
handle :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
    if res.async_state == nil {
        // Part 1 (IO thread): allocate work struct, call mark_async,
        // start background work, return immediately.
        work := new(My_Work, alloc)
        http.mark_async(h, res, work)
        // ... start background work ...
        return
    }

    // Part 2 (IO thread, resume call): background work is done.
    work := (^My_Work)(res.async_state)
    defer {
        // ... free work struct ...
        res.async_state = nil  // mandatory: signals end of async cycle
    }
    http.respond_plain(res, work.result)
}
```

`async_state` is the only shared state between Part 1 and Part 2. It points to a work
struct allocated in Part 1 on a persistent allocator (not `context.temp_allocator` from
a background thread — that arena is not thread-safe). Part 2 frees it.

---

## 4. Flow Diagrams

### Diagram A — Direct async (`without_body_async.odin`)

No body read needed. Part 1 goes async immediately.

```
IO Thread                                    Background Thread
─────────────────────────────────────────    ─────────────────────────────
handler (Part 1)
  work = new(Without_Body_Work, alloc)
  mark_async(h, res, work)                   ← async_pending += 1
  t = thread.create(background_proc)
  thread.start(t)
  return  ──────────────────────────────────► [background_proc runs]
                                               do slow work
IO thread free for other requests              store result in work
                                               resume(res)
                                                 mpsc.push(resume_queue, res)
                                                 nbio.wake_up(io_thread)
                                             ─────────────────────────────
[next nbio.tick()]
  resume loop dequeues res
  handler (Part 2)                           ← async_pending -= 1
    work = (^Without_Body_Work)(async_state)
    defer { join thread; free work; async_state = nil }
    respond_plain(res, work.result)
```

### Diagram B — Body-first async (`with_body_async.odin`)

Body must be read before work can start. The body callback is still on the IO thread.

```
IO Thread                                    Background Thread
─────────────────────────────────────────    ─────────────────────────────
handler (Part 1)
  res.async_handler = h    ← store h; callback only gets res, not h
  http.body(req, -1, res, body_callback)
  return  ──────────────────────────────────► IO thread reads body (async recv)

body_callback (IO thread, still Part 1)
  work = new(Body_Work, alloc)
  work.body = string(body)
  mark_async(res.async_handler, res, work)   ← async_pending += 1
  t = thread.create(body_background_proc)
  thread.start(t)
  return  ──────────────────────────────────► [body_background_proc runs]
                                               do slow work
IO thread free for other requests              store result in work
                                               resume(res)
                                                 mpsc.push + wake_up
                                             ─────────────────────────────
[next nbio.tick()]
  resume loop dequeues res
  handler (Part 2)                           ← async_pending -= 1
    work = (^Body_Work)(async_state)
    defer { join; free; async_state = nil }
    respond_plain(res, work.result)
```

### Diagram C — Same-thread split (`ping_pong.odin`)

No background thread. `mark_async` + `resume` called synchronously in the body callback,
both on the IO thread. Part 2 fires in the same event-loop tick.

```
IO Thread (single thread throughout)
─────────────────────────────────────────────────────────────────────────
handler (Part 1)
  res.async_handler = h
  http.body(req, -1, res, ping_pong_callback)
  return

ping_pong_callback (IO thread)              ← context.temp_allocator already set
  work = new(Ping_Pong_Work, temp_allocator)
  work.body = string(body)
  mark_async(res.async_handler, res, work)  ← async_pending += 1
  resume(res)                               ← mpsc.push + wake_up (same thread)

[same nbio.tick(), resume loop]
  handler (Part 2)                          ← async_pending -= 1
    work = (^Ping_Pong_Work)(async_state)
    defer { async_state = nil }
    respond_plain(res, "pong")  // or 422
```

---

## 5. Key Design Decisions

### Why mark_async / cancel_async / resume (not a simpler API)

`mark_async` must happen **before** background work starts because it increments
`async_pending`. If the background thread calls `resume` (which decrements the counter)
before `mark_async` runs, the counter goes negative-then-back and the server's shutdown
condition (`closing && async_pending == 0`) is satisfied prematurely.

`cancel_async` is needed for rollback when background work fails to start — it
decrements `async_pending` back. Without it, `async_pending` stays permanently
incremented and graceful shutdown waits forever.

`resume` must be called exactly once. Zero calls: the request is lost, the client waits
forever, shutdown hangs. Two calls: undefined behavior on the connection.

### Why MPSC

The resume queue is written by many background threads (producers) and read by exactly
one IO thread (consumer). MPSC is the correct primitive for this topology. A mutex-based
queue would work but introduces unnecessary contention; a channel would require an extra
allocation. The MPSC implementation is the lock-free Vyukov queue, generic over any
struct with `node: list.Node` as the first field.

`nbio.wake_up` was already present in the codebase (used by `server_shutdown`) — no new
OS primitive was needed. On Linux it writes to an `eventfd`; on Windows it calls
`QueueUserAPC`; on macOS it adds a `EVFILT_USER` kevent.

### Why the `async_handler` field

The original naive approach would always resume from `server.handler` (the chain head).
Any middleware sitting before the async handler would execute twice on Part 2 — double
logging, double rate-limiting, double side-effects. `mark_async` stores the exact handler
that went async in `res.async_handler`; the resume loop calls that handler directly.

### Why intrusive MPSC (node as first field of Response)

No allocation per enqueued response — the `node: list.Node` field is embedded directly
in `Response`. The `#assert(offset_of(Response, node) == 0)` compile-time guard fires
if `node` is ever moved from the first position, which would silently break the
`container_of` arithmetic in the MPSC queue.

### Memory ordering

All atomic operations in `mpsc.push` and `mpsc.pop` use Odin's default sequentially-
consistent ordering. The `atomic_store` in `push` acts as a release barrier; the
`atomic_load` in `pop` acts as an acquire barrier. This guarantees that all writes to
the work struct before `resume` are visible to the IO thread in Part 2 without any
explicit barrier or annotation in handler code.

---

## 6. Changes: Async Functionality

**`resume.odin`** (new file)
Public API: `mark_async`, `cancel_async`, `resume`. All three procs are IO-thread-only
except `resume`, which may be called from any thread.

**`response.odin`** (modified)
- Added `node: list.Node` as the first field of `Response` (intrusive MPSC node).
- Added `async_handler: ^Handler` — the exact handler to call in Part 2.
- Added `async_state: rawptr` — nil means sync; non-nil means async cycle in progress.
- Added `#assert(offset_of(Response, node) == 0)` — compile-time guard for MPSC layout.
- Added disconnect guard in `response_send`: if `async_state != nil` when the response
  is sent (client disconnected mid-async), Part 2 still runs for cleanup.

**`server.odin`** (modified)
- Added `Connection.owning_thread: ^Server_Thread` — set once in `on_accept`, never
  changes, no lock needed.
- Added `Server_Thread.resume_queue: mpsc.Queue` and `async_pending: int` (atomic).
- MPSC queue initialized in `_server_thread_init`.
- Resume loop added after `nbio.tick()`: drains `resume_queue` and re-invokes handlers.
- Shutdown exit condition extended: `s.closing && async_pending == 0`.
- `context.temp_allocator` saved and restored around each resume handler call
  (`old_temp` pattern) — see non-async fixes §7.3.

**`internal/mpsc/`** (new package)
Lock-free Vyukov MPSC queue, generic over any struct with `node: list.Node` as its
first field. Pure Odin — zero dependency on odin-http, nbio, or any external library.
Bundled as `internal/mpsc` and not part of the public API. May be proposed to Odin core
as `core:container/mpsc` or `core:sync/mpsc` separately; if accepted the import here
would switch from `internal/mpsc` to the core package.

---

## 7. Changes: Non-Async Fixes

These three fixes were found during stress and cross-platform testing. They are
independent of the async feature but are included in this PR as they were discovered
in the process.

### 7.1 `server.odin` — Shutdown loop

`_server_thread_shutdown` now uses `nbio.tick(1ms)` instead of a blocking tick.
During shutdown, only connections in state `.New`, `.Idle`, or `.Pending` are
force-closed; `.Active` connections are left to drain naturally. `conn_handle_req`
returns early when `atomic_load(&c.server.closing)` is true, preventing new recv
registrations after shutdown starts.

**Why:** force-closing `.Active` connections caused SIGBUS on macOS — after
`posix.close(fd)`, kqueue can still deliver already-queued `EVFILT_READ` events; if
`free(c)` had already run, `scanner_on_read` accessed a freed connection. The same guard
also fixes memory leaks during shutdown on Windows. Connections drain naturally:
`on_response_sent` → `clean_request_loop` → `conn_handle_req` returns early → no new
recv registered → connection transitions to `.Idle` → shutdown loop closes it safely.

### 7.2 `response.odin` — Log level in `on_response_sent`

`log.errorf` changed to `log.warnf` in the disconnect path of `on_response_sent`.

**Why:** the Odin test framework treats `log.errorf` as a test failure. A client
disconnecting while async work is in flight is expected behavior — the server still
runs Part 2 for cleanup — not an error condition worth failing a test over.

### 7.3 `server.odin` — `context.temp_allocator` save/restore in resume loop

The resume loop now saves `context.temp_allocator` before invoking each resume handler
and restores it afterward (the `old_temp` pattern).

**Why:** the initial resume loop set `context.temp_allocator` to the resumed connection's
arena but did not restore it. After the handler returned, subsequent event-loop iterations
on the same IO thread inherited a stale arena pointer from the last resumed connection.
Under stress this caused intermittent allocator-poisoning crashes.

---

## 8. Examples

`examples/async/` contains three ready-to-use examples (package `async_examples`):

- `without_body_async.odin` — direct async: Part 1 goes async immediately, no body read
- `with_body_async.odin` — body-first: body is read asynchronously, then goes async
- `ping_pong.odin` — same-thread split: no background thread; `mark_async` + `resume`
  called synchronously in the body callback on the IO thread

**Note:** all three examples use `thread.create` per request. This is a learning pattern
chosen to show the flow clearly — it does not scale to production load. A real server
uses a worker pool or job queue; only the glue code that signals completion calls
`http.resume(res)`. The examples are intentionally kept simple so the async mechanics
are not obscured by infrastructure concerns.
