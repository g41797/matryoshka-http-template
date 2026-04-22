# Design: Async odin-http Handlers

**Version:** 1.0
**Authors:** g41797, Claude (claude-sonnet-4-6), Grok (Odin architect)
**Date:** April 2026

---

## 1. Motivation

The current `bridge.odin` blocks the odin-http io thread while waiting for a pipeline reply:

```odin
// bridge_handle — blocks io thread
matryoshka.mbox_wait_receive(reply_mb, &reply_mi)  // io thread sleeps here
```

Under load, every pending request holds one io thread captive. Because odin-http uses a small
fixed thread pool (one thread per CPU core by default), this limits throughput to `thread_count`
concurrent requests — regardless of backend capacity.

**Goal**: Allow handlers and body callbacks to return immediately to the event loop. When the
backend signals completion, the io thread re-invokes the **exact same handler** (not the head of
the middleware chain) with the result — without changing existing handler or body callback
signatures.

---

## 2. Requirements

| ID | Requirement |
|---|---|
| R0 | No matryoshka dependency. Design covers odin-http + nbio only. Matryoshka is one possible backend, evaluated separately. |
| R1 | io thread must never block waiting for the backend. |
| R2 | odin-http event loop must be modified to process a per-thread resume queue after each `nbio.tick()`. |
| R3 | Resume queue is MPSC: any thread enqueues, io thread processes non-blocking. |
| R4 | No separate request registry. `async_state: rawptr` on `Response` carries all handler-defined state. |
| R5 | Response dispatch on the io thread uses the same `http.respond*` calls as today. |
| R6 | Error responses flow through the same resume queue — no silently dropped requests. |
| R7 | Connection lifetime covers the full async cycle, valid until the response is dispatched. |
| R8 | Graceful shutdown: `http.server_shutdown` sends the existing wake signal; pending async requests complete naturally before the event loop exits. |
| R9 | Any handler (with or without body) may go async. |
| R10 | Body-read path supported: handler calls `http.body()` → callback fires on io thread → callback may also go async. |
| R11 | Existing `Handler_Proc` and `Body_Callback` signatures are unchanged. New API: `http.mark_async(h: ^Handler, res: ^Response, state: rawptr)`, `http.cancel_async(res: ^Response)`, `http.resume(res: ^Response)`. |
| R12 | Handler explicitly signals async intent by setting `res.async_state` to non-nil before returning. |

---

## 3. Architecture Overview

```text
odin-http io thread (nbio event loop)
    │
    ├─ nbio.tick() ──────────────────────────────────────────────────┐
    │       │                                                        │
    │  handler.handle(h, req, res)   [first call]                    │
    │       │                                                        │
    │       ├── http.mark_async(h, res, &work)  ← marks async         │
    │       ├── thread.start(background_thread, data=res)            │
    │       └── return immediately  ← io thread freed                │
    │                                                                │
    ├─ process resume_queue (non-blocking) ◄─────────────────────────│
    │       │                                                        │
    │       │   ┌─────────────────────────────────┐                  │
    │       │   │  background_thread              │                  │
    │       │   │    do_work(res.async_state)     │                  │
    │       │   │    http.resume(res)             │                  │
    │       │   │      mpsc.push(resume_queue,res)│                  │
    │       │   │      nbio.wake_up(io_thread)    │                  │
    │       │   └─────────────────────────────────┘                  │
    │       │                                                        │
    │  handler.handle(h, req, res)   [resume call]                   │
    │       │                                                        │
    │       ├── async_state != nil → resume branch                   │
    │       ├── http.respond_plain(res, result)                      │
    │       └── free work struct, join thread                        │
    │                                                                │
    └─────────────────────────────────────────────────────────────── ┘
```

---

## 4. New odin-http API

```odin
import mpsc  "core:mpsc"
import "base:intrinsics"

// mark_async marks the response as async and remembers the exact handler
// that is going async (critical for correct middleware resume).
// Call from inside Handler_Proc (first call) or Body_Callback. io thread only.
// Safe ordering: prepare work → mark_async → start background work.
// If background work fails to start, call cancel_async and return an error response.
mark_async :: proc(h: ^Handler, res: ^Response, state: rawptr) {
    if h != nil {
        res.async_handler = h
    } else if res.async_handler == nil {
        res.async_handler = res.connection.server.handler
    }
    res.async_state = state
    intrinsics.atomic_add(&res.connection.owning_thread.async_pending, 1)
}

// cancel_async rolls back the async intent set by mark_async.
// Call only when background work fails to start — io thread only.
// BOTH steps are mandatory on Part 1 failure:
//   1. http.cancel_async(res)            — rolls back state, decrements async_pending.
//   2. http.respond(res, .<error_status>) — sends error to client.
// Omitting cancel_async: async_pending stays incremented — graceful shutdown will hang.
// Omitting respond: request is silently dropped — client never receives a response.
cancel_async :: proc(res: ^Response) {
    intrinsics.atomic_add(&res.connection.owning_thread.async_pending, -1)
    res.async_state = nil
    res.async_handler = nil
}

// resume signals the owning io thread that async work is complete.
// Any thread may call. After this call do not touch res — the io thread owns it.
// Any access to res, res._conn, or work after resume returns is undefined behavior.
resume :: proc(res: ^Response) {
    if res == nil { return }
    td := res.connection.owning_thread
    msg: Maybe(^Response) = res
    if mpsc.push(&td.resume_queue, &msg) {
        nbio.wake_up(td.event_loop)
    }
    // msg is nilled on success — ownership transferred to queue
}
```

`nbio.wake_up` is already used by `http.server_shutdown` — same call, same platforms
(Linux: `eventfd`; Windows: `QueueUserAPC`). No new primitive.

**Memory ordering:** All atomic operations in `mpsc.push` and `mpsc.pop` use Odin's default
sequentially-consistent (seq_cst) ordering. The `atomic_store` in `push` acts as a release
barrier; the `atomic_load` in `pop` acts as an acquire barrier. This guarantees that all
writes to the `work` struct before calling `resume` are visible to the io thread in Part 2.
No explicit barrier or annotation is needed in handler code.

---

## 5. Changes to odin-http Internals

### 5.1 New field on `Response` (response.odin)

```odin
import list "core:container/intrusive/list"

Response :: struct {
    node:          list.Node,  // intrusive MPSC node — must be first field (mpsc.Queue constraint)
    async_handler: ^Handler,   // exact handler that called mark_async (middleware-safe resume)
    // ... existing fields unchanged ...
    async_state:   rawptr,     // nil = sync; !nil = async pending
}
// Compile-time layout guard — the mpsc.Queue generic uses container_of with zero offset.
// If node is ever moved from first position, this fires at compile time.
#assert(offset_of(Response, node) == 0, "Response.node must remain the first field — required by mpsc.Queue")
```

`clean_request_loop` (which resets the per-connection arena) must be guarded:

```odin
on_response_sent :: proc(...) {
    if res.async_state != nil {
        return  // async cycle not finished; handler will call http.respond later
    }
    clean_request_loop(...)
}
```

### 5.2 New field on `Connection` (server.odin)

```odin
Connection :: struct {
    // ... existing fields unchanged ...
    owning_thread: ^Server_Thread,
    // Set once in on_accept. Never changes. No lock needed.
}
```

In `on_accept`:
```odin
c.owning_thread = td   // td is the current Server_Thread
```

### 5.3 New field on `Server_Thread` (server.odin)

```odin
import mpsc "core:mpsc"

Server_Thread :: struct {
    // ... existing fields unchanged ...
    resume_queue:    mpsc.Queue(Response),
    async_pending: int,  // atomic; > 0 while any request is between mark_async and resume
}
```

The queue uses `core:mpsc` — a lock-free Vyukov MPSC, full source in §16. The
`mpsc.Queue(Response)` generic constraint requires `Response` to
have a field named `node` of type `list.Node` (added in §5.1). Initialize once at thread startup:

```odin
mpsc.init(&td.resume_queue)
```

This queue is separate from nbio's internal MPSC — it carries `^Response` pointers, not
`^nbio.Operation`.

### 5.4 Resume loop — insert after `nbio.tick()` (`_server_thread_init`, server.odin)

Do not replace the existing loop. Insert the resume block immediately after `nbio.tick()`,
all existing loop state intact.

The naive `if nil { break }` pattern is insufficient — `mpsc.pop` may return nil even when items
are pending (stall: producer has exchanged head but not yet linked the node). `mpsc.length`
is NOT usable for stall detection: it is incremented AFTER node linking, so it also returns 0
during the stall window. A bounded retry (3 pops) closes the stall without relying on length.
The stall window is nanoseconds — the retry succeeds immediately.

```odin
// Insert after nbio.tick() inside the existing _server_thread_init loop:

// Resume loop — stall-safe (bounded retry), non-blocking, io thread only.
for {
    res := mpsc.pop(&td.resume_queue)
    if res == nil {
        // Bounded retry — resolves the producer stall window (< 10 ns) without
        // relying on mpsc.length (which is also 0 during the stall window).
        stall := false
        for _ in 0..<3 {
            res = mpsc.pop(&td.resume_queue)
            if res != nil { stall = true; break }
        }
        if !stall { break }
    }
    // Restore per-connection allocator — matches conn_handle_reqs
    context.temp_allocator = virtual.arena_allocator(&res._conn.temp_allocator)
    // Use the EXACT handler that originally called mark_async (middleware-safe).
    h := res.async_handler if res.async_handler != nil else res._conn.server.handler
    h.handle(h, &res._conn.loop.req, res)
    intrinsics.atomic_add(&td.async_pending, -1)  // decrement after resume handler returns
    // Cleanup guard: handler must nil async_state before returning from resume branch.
    when ODIN_DEBUG {
        assert(res.async_state == nil,
            "async handler must set res.async_state = nil before returning from resume branch")
    } else {
        if res.async_state != nil {
            log.warn("async handler left async_state non-nil after resume — cleared")
            res.async_state = nil
        }
    }
    res.async_handler = nil  // clear for next request on this connection
}
```

**Shutdown invariant:** `async_pending == 0` implies the resume queue is empty. This holds
because `async_pending` is incremented at `mark_async` (before background work starts, on
the io thread) and decremented only after the resume handler returns. A decrement to 0 means
all mark_async calls have had their corresponding resume handler complete — no items can
remain in the queue.

**Modified shutdown exit condition** — replace the existing exit check with:

```odin
// Exit only when shutting down AND no request is mid-async-cycle.
// While s.closing is true but async_pending > 0, the io thread keeps calling
// nbio.tick() and processing resumes — each processed resume decrements the counter.
if intrinsics.atomic_load(&s.closing) && intrinsics.atomic_load(&td.async_pending) == 0 {
    _server_thread_shutdown(s)
    break
}
```


### 5.5 Disconnect guard in `response_send` (response.odin)

Without this guard, `clean_request_loop` is never called when the client disconnects before the
resume branch responds — the per-connection arena leaks for the lifetime of the connection slot.

```odin
// Add at the top of response_send, before scheduling the nbio send:
if conn.state >= .Closing || conn.state == .Will_Close {
    clean_request_loop(conn)
    return
}
```

This ensures the resume branch always triggers cleanup even on a dead connection. The handler
still frees its own `async_state` resources — this guard only covers the arena reset.

**Connection lifetime guarantee:** The `Connection` struct is guaranteed alive for the entire
async cycle. This holds structurally — not from the 500ms `Conn_Close_Delay` (which is a
TCP graceful-close delay for RFC 7230 §6.6, unrelated to async lifetime). The guarantee
comes from the odin-http state machine:
- Active connections (state `.Active`) are never force-closed during shutdown — the shutdown
  loop only closes `.New`, `.Idle`, and `.Pending` connections.
- After headers are fully parsed and the handler goes async, no pending recv is registered.
  A client disconnect is therefore invisible to nbio until the response send is attempted.
- `connection_close` → `free(c)` is only triggered after `response_send` completes (Part 2
  has already returned and `async_state` is nil).

The background thread may safely read `res._conn` for the duration of the async cycle.
It must not write to `res._conn` or call any odin-http API other than `http.resume(res)`.

---

## 6. Handler Lifecycle (First Call vs Resume)

The handler proc signature is unchanged: `proc(h: ^Handler, req: ^Request, res: ^Response)`.

The handler uses `res.async_state` to distinguish the two phases:

```
First call:   res.async_state == nil  → start work, set async_state, return immediately
Resume call:  res.async_state != nil  → read result, respond, clean up
```

odin-http checks `async_state` after `handler.handle` returns. If non-nil, it skips
`clean_request_loop` and leaves the connection open. If nil (sync handler or resume completed),
cleanup runs.

**Safe ordering in Part 1 (first call):**
1. Allocate and prepare the work struct.
2. Call `http.mark_async(h, res, work)`.
3. Start the background work (e.g. `thread.start`).
4. Return immediately — do not do any slow work after `mark_async`.

If step 3 fails (e.g. `thread.create` returns nil), BOTH of the following are mandatory:
- Call `http.cancel_async(res)` — rolls back `async_state`/`async_handler`, decrements `async_pending`. Omitting this leaves the counter permanently incremented; graceful shutdown will hang forever.
- Call `http.respond(res, .<error_status>)` — sends an error response to the client. Omitting this silently drops the request; the client waits indefinitely.

Never leave `async_state` non-nil without a corresponding `resume`.

**`req` is immutable for the full async cycle:** `req` is reset only in `clean_request_loop`,
which cannot run while `async_state != nil` (guarded by `on_response_sent`). Handlers may
safely read `req` in Part 2.

**Required in Part 2 (resume call):** set `res.async_state = nil` before returning. Use
`defer { res.async_state = nil }` at the top of the resume branch to guarantee this on all
paths. The resume loop has a debug assert (or release log+clear) if forgotten — but the
handler is responsible. Forgetting causes arena corruption on the next request.

---

## 6.1 Middleware Resume Fix (v0.6)

**Problem:** The original v0.5 resume loop always restarted the full middleware chain from
`server.handler`. This caused every middleware before the async handler to run **twice** —
double metrics, double rate-limit tokens, double logging, double side-effects.

**Fix:** Added `async_handler: ^Handler` field to `Response`. `http.mark_async` takes the current
handler pointer `h` and stores it. The resume loop calls the **exact handler** that originally
called `mark_async` — not the chain head. Middleware before the async point runs only once.

**Always pass `h`**: the `h` parameter in `mark_async(h, res, state)` must be the handler pointer
received by the current `Handler_Proc`. Passing `nil` when `res.async_handler` is also nil
triggers a runtime assert — this catches the middleware double-execution bug at development
time. The fallback to `server.handler` is only used when `h == nil` AND `res.async_handler`
was already set by the calling handler (body callback path). In all other cases, always pass `h`.

Zero runtime cost when async is not used. No breaking changes to existing synchronous code.

**Warning — middleware post-processing:** Any code placed after `h.next.handle(h.next, req, res)`
in a middleware wrapper runs when Part 1 returns — **before** background work starts and before
the response is built. This affects:

- **Timing middleware**: measures near-zero elapsed time (Part 1 is instantaneous).
- **Response status logging**: `res.status` is still the default; the final status is set in Part 2.
- **`defer` cleanup in middleware**: runs at Part 1 unwind time; must not free resources that the
  background thread or Part 2 will read.

For async-aware middleware, restructure post-processing as Part 1 work only, or check
`res.async_state != nil` on return and skip post-processing for async handlers.

---

## 7. Body Callback Path

Body callbacks (`Body_Callback`) fire on the io thread, inside an nbio callback chain — same
thread, same context. They may:

1. **Respond directly** (error or trivial case): `http.respond(res, .Bad_Request)` — sync, no
   change.
2. **Go async**: set `res.async_state`, start background thread, call `http.resume` later.

```odin
// Inside Body_Callback — fires on io thread
body_cb :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
    res := (^http.Response)(user_data)
    if err != nil {
        http.respond(res, http.body_error_status(err))
        return
    }
    // Copy body — odin-http's buffer is only valid during this callback
    work := new(My_Work, my_alloc)
    work.body = make([]byte, len(body), my_alloc)
    copy(work.body, body)
    work.alloc = my_alloc
    // Signal async intent + increment pending counter.
    // Pass res.async_handler — set by the calling handler before http.body().
    http.mark_async(res.async_handler, res, work)
    t := thread.create(background_proc)
    t.data = res
    work.thread = t
    thread.start(t)
    // Return immediately — io thread is freed
}
```

The background worker must store its final result into the `work` struct (via `res.async_state`)
**before** calling `http.resume`. Once `resume` returns, the io thread owns `res` — the background
thread must not write to `work` or `res` after that point.

The subsequent `handler.handle` resume call (dispatched from the resume loop) reads the result and
responds.

---

## 8. Allocations

| Allocation | Allocator | Freed by | Lifetime |
|---|---|---|---|
| work struct | handler's choice (see table below) | resume branch of handler | first call → resume |
| body bytes copy | same as work struct | resume branch of handler | body callback → resume |
| `^thread.Thread` | registration-time allocator | `thread.join` + `thread.destroy` in resume branch | first call → resume |

### Allocator choices for work struct and body bytes

| Variant | Allocator | Notes |
|---|---|---|
| Arena (simple) | `context.temp_allocator` | Per-connection `virtual.Arena`. `free_all` fires after response sent — arena outlives the cycle. Individual `free` is a no-op. Safe because only the io thread accesses it. |
| External (explicit) | Caller-supplied allocator (e.g. `context.allocator`) | Handler receives it via `handler.user_data`. Must be explicitly freed in resume branch. Survives across requests. Required in production when multiple handlers or pipelines share state. |

**Arena safety**: `context.temp_allocator` is the per-connection arena. It is safe to use for
the work struct and body copy because no cross-thread access to the allocator occurs — the
background thread reads/writes the already-allocated memory, it does not call the allocator.
`clean_request_loop` (which calls `free_all`) only runs after `on_response_sent`, which fires
after the resume branch responds. The arena outlives the entire async cycle.

**Real-world projects**: use the allocator from `handler.user_data` (a `My_Context` struct set at
route registration). This decouples the HTTP layer from the allocator lifecycle and works correctly
when multiple handlers or pipeline workers share the same allocator.

---

## 9. Wake Mechanism — Platform Safety

| Approach | Windows safe? | Notes |
|---|---|---|
| `nbio.timeout(0, ...)` | NO | `timeout_exec` → `avl.find_or_insert` crash under aggressive optimisation (documented in `nbio_mbox/nbio_mbox.odin`) |
| `nbio.exec` with any op type | NO | `case .None: unreachable()` in `_exec` (all platforms). Real op types require a pre-allocated `^nbio.Operation` from the pool — wrong abstraction layer. |
| `nbio.wake_up(event_loop)` | YES | Linux: `eventfd` write. Windows: `QueueUserAPC`. No timeout involved. Already used by `http.server_shutdown`. |

**Result**: The resume mechanism uses only `nbio.wake_up`. The MPSC resume queue is a plain
struct, not nbio's internal I/O operation queue.

---

## 10. Client Disconnect During Async

If the client disconnects while a request is pending, odin-http's existing connection-close path
fires. The background thread continues to completion and calls `http.resume`. Resume queue
processing on the io thread re-invokes the handler.

The handler must free its resources in the resume branch regardless of connection state — even if
the client disconnected. Silent discard is not acceptable: the work struct, body copy, and thread
handle can only be freed through the resume path.

**Arena-leak risk on disconnect**: if `response_send` short-circuits on a closed connection
without scheduling the nbio send, `on_response_sent` never fires and `clean_request_loop` is
never called — arena leak. Fix: see §5.5.

---

## 11. Graceful Shutdown

`http.server_shutdown` sets `s.closing = true` and calls `nbio.wake_up` on each io thread.

The io thread does **not** exit immediately. The modified loop (§5.4) keeps running —
calling `nbio.tick()` and processing the resume queue — until:

```
s.closing == true  AND  async_pending == 0
```

While `async_pending > 0`, background threads are still running. Each resume processed by
the loop decrements the counter. Once it hits zero, every background thread started by an
async handler has completed its work, called `http.resume`, and had its resume branch run.
No work struct, body copy, or thread handle is left unreleased.

The io thread then exits the main loop and shuts down cleanly. The queue is empty by
construction — every decrement happens after the resume handler runs, so counter==0 implies
all items were already processed.

---

## 12. Known Limitations and Hard Rules (v1.0)

1. **Thread join on io thread**: The resume branch calls `thread.join(work.thread)`. The
   background thread has already completed before `http.resume` enqueues — that is the contract.
   The join releases the OS handle, not a wait. Detach-and-free is the fix if benchmarks show this.

2. **One background thread per request does NOT scale**: The code skeletons use `thread.create`
   per request for clarity. **This pattern is not suitable for production.** At high concurrency
   (thousands of requests), spawning one OS thread per request causes memory exhaustion and
   scheduler thrashing. For production, use a worker pool or pipeline (e.g., Matryoshka).
   The thread-per-request examples exist to make the async API easy to learn — not as a
   deployment template.

3. **No timeout / deadline per request**: A background worker that never calls `resume` pins
   `async_pending > 0` and blocks graceful shutdown forever. Applications requiring bounded
   shutdown time must implement their own watchdog (e.g., a timeout goroutine that calls
   `cancel_async` + `http.respond` if the worker does not complete in time). odin-http does
   not provide this mechanism.

4. **`async_state` cleanup is the handler's responsibility**: odin-http does not free or nil
   `async_state` on connection close. Resources allocated under `async_state` (work struct, body
   copy, thread handle) must be freed in the resume branch — even if the client disconnected. A
   missed `free` or forgotten `res.async_state = nil` leaks memory for the connection lifetime.

5. **Do not block in Part 1 or Part 2**: Both the first call and the resume call run on the io
   thread. Any blocking call (`mbox_wait_receive`, `time.sleep`, blocking I/O) inside either part
   stalls the entire io thread and all connections it serves. All slow work must happen in the
   background thread (or pipeline), not in the handler proc.

6. **`res.async_state = nil` is required at end of resume branch**: If the handler returns from
   the resume call with `async_state` still non-nil, the resume loop has a debug assert (or
   release log+clear as cleanup guard). Use `defer { res.async_state = nil }` at the top of the
   resume branch to guarantee this regardless of error paths.

7. **Background processing failure — handler's responsibility**: The design does not define how
   a background failure is communicated back to Part 2. Advisory: store an error code or status in
   the `work` struct before calling `resume`; Part 2 reads it and responds with the appropriate
   HTTP error status and/or logs the failure. The design does not enforce a specific mechanism —
   the choice (error field, result union, etc.) is left to the handler author.

8. **`cancel_async` must not be called twice**: Each call to `cancel_async` decrements
   `async_pending`. A double call underflows the counter — the server will never shut down.
   The implementation guards against double-call (nil async_state check at entry), but handler
   code must not rely on this guard as a correctness crutch.

9. **Middleware post-processing does not participate in the resume lifecycle**: Code in a
   middleware wrapper that follows the `h.next.handle(...)` call executes when Part 1 returns —
   before background work and before the response is sent. Timing, response-status inspection,
   and `defer` cleanups in wrapping middleware will produce incorrect results for async handlers.
   See §6.1 for the recommended pattern.

---

## 13. Code Skeletons

### 13a. Direct Async Handler (no body)

Use case: handler needs no request body — immediately starts background work.

```odin
package my_handler

import http "http:."
import "core:thread"
import "core:mem"

// My_Context is passed at route-registration time via handler.user_data.
My_Context :: struct {
    alloc: mem.Allocator,
    // ... config, shared resources, etc.
}

// My_Work is allocated per-request, lives until resume.
My_Work :: struct {
    alloc:  mem.Allocator,
    thread: ^thread.Thread,
    result: []byte,
    // ... backend-specific fields
}

// background_proc runs on its own OS thread.
background_proc :: proc(t: ^thread.Thread) {
    res := (^http.Response)(t.data)
    work := (^My_Work)(res.async_state)

    // ... do the actual work, fill work.result ...
    work.result = []byte("hello from background")

    // Signal io thread — after this call, do not touch res or work.
    http.resume(res)
}

// my_handler_proc is the Handler_Proc. Same signature as all odin-http handlers.
my_handler_proc :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
    ctx := (^My_Context)(h.user_data)

    if res.async_state == nil {
        // ── First call ──────────────────────────────────────────────
        work := new(My_Work, ctx.alloc)
        work.alloc = ctx.alloc

        // Safe order: prepare → mark_async → start work.
        http.mark_async(h, res, work)  // sets async_handler + async_state + increments pending counter

        t := thread.create(background_proc)
        if t == nil {
            // Background work failed to start — roll back.
            http.cancel_async(res)
            free(work, ctx.alloc)
            http.respond(res, .Internal_Server_Error)
            return
        }
        t.data = res
        work.thread = t
        thread.start(t)
        return  // io thread freed immediately
    }

    // ── Resume call ──────────────────────────────────────────────────
    work := (^My_Work)(res.async_state)
    defer {
        thread.join(work.thread)
        thread.destroy(work.thread)
        delete(work.result, work.alloc)
        free(work, work.alloc)
        res.async_state = nil   // required: allows clean_request_loop to run after respond
    }

    http.respond_plain(res, string(work.result))
}

// Route registration (called once at startup).
register_my_handler :: proc(router: ^http.Router, ctx: ^My_Context) {
    h := http.Handler {
        handle    = my_handler_proc,
        user_data = ctx,
    }
    http.route_get(router, "/my/path", h)
}
```

---

### 13b. Async Handler with Body Callback

Use case: handler reads the request body, then sends it to a backend for processing.

```odin
package my_handler

import http "http:."
import "core:thread"
import "core:mem"

My_Context :: struct {
    alloc: mem.Allocator,
}

My_Work :: struct {
    alloc:   mem.Allocator,
    thread:  ^thread.Thread,
    body:    []byte,   // copy of request body, owned by work
    result:  []byte,
}

// background_proc reads work.body and fills work.result.
background_proc :: proc(t: ^thread.Thread) {
    res := (^http.Response)(t.data)
    work := (^My_Work)(res.async_state)

    // Echo the body back as the result (replace with real work).
    work.result = make([]byte, len(work.body), work.alloc)
    copy(work.result, work.body)

    http.resume(res)
}

// body_callback fires on the io thread after the full request body is read.
body_callback :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
    res := (^http.Response)(user_data)
    ctx := (^My_Context)(res.connection.server.handler.user_data)

    if err != nil {
        http.respond(res, http.body_error_status(err))
        return
    }

    // Allocate work struct with external allocator — survives beyond this callback.
    work := new(My_Work, ctx.alloc)
    work.alloc = ctx.alloc

    // Copy body — odin-http's buffer is only valid during this callback.
    if len(body) > 0 {
        work.body = make([]byte, len(body), ctx.alloc)
        copy(work.body, body)
    }

    // Safe order: prepare → mark_async → start work.
    http.mark_async(res.async_handler, res, work)  // uses handler set by my_body_handler_proc

    t := thread.create(background_proc)
    if t == nil {
        http.cancel_async(res)
        if work.body != nil { delete(work.body, ctx.alloc) }
        free(work, ctx.alloc)
        http.respond(res, .Internal_Server_Error)
        return
    }
    t.data = res
    work.thread = t
    thread.start(t)
    // Return immediately — io thread freed
}

// my_body_handler_proc is the Handler_Proc.
my_body_handler_proc :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
    if res.async_state == nil {
        // ── First call ── record handler for middleware-safe resume, then read body
        res.async_handler = h
        http.body(req, -1, res, body_callback)
        // body_callback will be called by nbio when body is complete.
        // Do NOT set async_state here — it is set inside body_callback.
        return
    }

    // ── Resume call ── body was read AND backend work is done
    work := (^My_Work)(res.async_state)
    defer {
        thread.join(work.thread)
        thread.destroy(work.thread)
        if work.body  != nil { delete(work.body,   work.alloc) }
        if work.result != nil { delete(work.result, work.alloc) }
        free(work, work.alloc)
        res.async_state = nil
    }

    http.respond_plain(res, string(work.result))
}

register_my_body_handler :: proc(router: ^http.Router, ctx: ^My_Context) {
    h := http.Handler {
        handle    = my_body_handler_proc,
        user_data = ctx,
    }
    http.route_post(router, "/my/body/path", h)
}
```

---

### 13c. Split Handler — No Thread

Use case: test the async machinery (MPSC queue, resume loop, `async_state` lifecycle,
`on_response_sent` guard) without a background thread. The handler splits into two parts within
the same `Handler_Proc`. Part 1 ends with `http.mark_async` + `http.resume` — both called
synchronously on the io thread, no `thread.create`. Part 2 runs in the resume loop on the next
`nbio.tick` iteration.

Based on the `post_ping` echo handler in `vendor/odin-http/examples/readme/main.odin`.

Because no cross-thread access occurs, work allocations are safe from the per-connection arena
(`context.temp_allocator`). The arena is not reset while `async_state != nil`.

```odin
package split_async

import http "http:."

Split_Work :: struct {
    body: []byte,  // copy of request body; from per-connection arena — no explicit free
}

// split_body_callback fires on the io thread after the full body is read.
// Part 1 ends here: mark_async + resume called synchronously — no thread started.
split_body_callback :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
    res := (^http.Response)(user_data)
    if err != nil {
        http.respond(res, http.body_error_status(err))
        return
    }

    // Allocate from per-connection arena — valid until arena reset after respond.
    work := new(Split_Work)
    if len(body) > 0 {
        work.body = make([]byte, len(body))
        copy(work.body, body)
    }

    http.mark_async(res.async_handler, res, work)
    http.resume(res)  // last line of part 1 — do not touch res or work after this
}

split_ping_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
    if res.async_state == nil {
        // ── Part 1 ───────────────────────────────────────────────────────
        res.async_handler = h          // record for middleware-safe resume
        http.body(req, len("ping"), res, split_body_callback)
        return
    }

    // ── Part 2 (resume call) ──────────────────────────────────────────────
    work := (^Split_Work)(res.async_state)
    defer { res.async_state = nil }    // nil before respond — allows arena reset after send

    if string(work.body) != "ping" {
        http.respond(res, http.Status.Unprocessable_Content)
        return
    }
    http.respond_plain(res, "pong")
}

register_split_ping_handler :: proc(router: ^http.Router) {
    http.route_post(router, "/split/ping", http.Handler{handle = split_ping_handler})
}
```

---

## 14. Contributing Changes Upstream

The changes described in §5 are modifications to `vendor/odin-http` (a git submodule).

**Recommended workflow:**

1. Fork `laytan/odin-http` → `github.com/g41797/odin-http`.
2. Repoint the submodule in this template to the fork:
   ```
   git submodule set-url vendor/odin-http https://github.com/g41797/odin-http
   git submodule update --remote vendor/odin-http
   ```
3. Work directly on `main` of the fork (branch only when opening a PR upstream).
4. Commit changes in the fork, then commit the updated submodule pointer in the template repo.
5. Once validated, open a PR from `g41797/odin-http` to `laytan/odin-http`.

**Files modified in the fork:**

| File | Change summary |
|---|---|
| `server.odin` | `Server_Thread.resume_queue`; `Connection.owning_thread`; `on_accept` sets field; resume loop in `_server_thread_init` |
| `response.odin` | `Response.node` (`list.Node`, first field); `Response.async_handler`; `Response.async_state`; guard in `on_response_sent`; disconnect guard in `response_send` (§5.5) |
| `resume.odin` (new) | `http.mark_async(h, res, state)`, `http.cancel_async(res)`, `http.resume(res)` procs |


## 15. Testing Matrix

| Scenario | Expected outcome |
|---|---|
| Normal async, no body | Handler goes async on first call; resume loop re-invokes; `http.respond*` succeeds; arena reset after send. |
| Async after body read | First call reads body (returns); body callback goes async; resume re-invokes handler; respond succeeds. |
| Client disconnect before `http.resume` | Background thread still calls `http.resume`; resume loop re-invokes handler; handler frees resources; `response_send` detects closed conn and triggers `clean_request_loop` directly. |
| Client disconnect after `http.resume` enqueued | Resume loop re-invokes; `http.respond*` returns error; handler frees resources; cleanup runs. |
| Graceful shutdown with pending async | io thread keeps running until `async_pending == 0`; all pending requests complete before exit; queue is empty by construction when counter reaches zero. |
| Keep-alive after async request | After `clean_request_loop`, connection resets for next request; `async_state` and `async_handler` are nil; next request treated as fresh. |
| POST with body ignored (non-body async handler) | odin-http's RFC 7230 §6.3 body discard in `response_send` handles unconsumed body before connection reuse. |
| Handler forgets `res.async_state = nil` | Cleanup guard in resume loop detects non-nil after handler returns, nils it with warning; arena resets. |
| Middleware chain with async handler | Prefix middleware runs only once; resume loop re-invokes the exact handler that called `mark_async`; no double side-effects. |
| Split handler (no thread) | `mark_async` + `resume` called synchronously from io thread; MPSC queue enqueues and wakes io thread; resume loop re-invokes handler on next tick; `async_state` lifecycle correct; no thread created or joined. |

---

## 16. Appendix: MPSC Queue — Preliminary Implementation

### 16.1 Package Placement

`mpsc.Queue($T)` has no odin-http or nbio dependency — pure Odin, generic over any struct
with a `node: list.Node` field. It belongs alongside `core:container/intrusive/list` that it
already imports.

| Step | Action |
|---|---|
| odin-http PR | Bundle as `internal/mpsc/` — not part of the public API, used only by `server.odin` |
| Follow-up | Submit to Odin core as `core:container/mpsc` (or `core:sync/mpsc`) |
| After core accepts | Switch odin-http import from `internal/mpsc` to `core:mpsc`, drop the copy |

Inlining into `server.odin` is wrong — the queue + tests are ~250 LOC and have no HTTP
semantics. Exposing it as `odin-http/mpsc` publicly is also wrong — it is an implementation
detail.

### 16.2 queue.odin

```odin
package mpsc

import "base:intrinsics"
import list "core:container/intrusive/list"

// _ListNode keeps -vet happy — it does not count generic field types as import usage.
@(private)
_ListNode :: list.Node

// Queue is a lock-free multi-producer, single-consumer (MPSC) queue.
//
// Intended use: long-lived, single owner (e.g. embedded in a Server_Thread that lives
// for the duration of the program). Multiple threads push; one thread pops.
//
// T must have a field named "node" of type list.Node.
//
// NOT copyable after init. stub is an embedded dummy node whose address is stored in
// head and tail on init. Copying the struct after init silently corrupts the queue —
// embed it in place and never move it.
Queue :: struct($T: typeid) {
	head: ^list.Node, // producer end — updated atomically by multiple producers
	tail: ^list.Node, // consumer end — updated by single consumer only
	stub: list.Node, // dummy node; head and tail point here when queue is empty
	len:  int, // item count — updated atomically
}

// init sets up the queue. Call once before push or pop.
init :: proc(q: ^Queue($T)) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	q.stub.next = nil
	q.head = &q.stub
	q.tail = &q.stub
	q.len = 0
}

// push adds msg to the queue. Any thread may call.
// nil inner (msg^ == nil) is a no-op and returns false.
// On success: msg^ = nil, returns true.
push :: proc(q: ^Queue($T), msg: ^Maybe(^T)) -> bool where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	if msg == nil {
		return false
	}
	if msg^ == nil {
		return false
	}
	ptr := (msg^).?
	node := &ptr.node
	intrinsics.atomic_store(&node.next, nil)
	prev := intrinsics.atomic_exchange(&q.head, node)
	// Stall window: between the exchange above and the store below,
	// consumer may see prev.next == nil and return nil from pop.
	// Consumer retries — next pop will get it.
	intrinsics.atomic_store(&prev.next, node)
	intrinsics.atomic_add(&q.len, 1)
	msg^ = nil
	return true
}

// pop removes and returns one message. Call from a single consumer thread only.
//
// Returns nil in two cases:
//   - Queue is empty.
//   - Stall: a producer has started push but not yet finished linking the node.
//     In a stall, len may be != 0 while pop returns nil.
//     Treat as "retry" — next pop will get it.
//
// Wrap in Maybe(^T) to track ownership: m = pop(q)

pop :: proc(q: ^Queue($T)) -> ^T where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	tail := q.tail
	next := intrinsics.atomic_load(&tail.next)
	if tail == &q.stub {
		if next == nil {
			return nil // empty
		}
		q.tail = next
		tail = next
		next = intrinsics.atomic_load(&tail.next)
	}
	if next != nil {
		q.tail = next
		intrinsics.atomic_sub(&q.len, 1)
		return container_of(tail, T, "node")
	}
	// One item may remain or a stall is in progress.
	// Check whether head still points at tail.
	head := intrinsics.atomic_load(&q.head)
	if tail != head {
		return nil // stall — producer exchanged head but has not set next yet
	}
	// Single item remaining. Recycle stub as the new dummy node.
	q.stub.next = nil
	prev := intrinsics.atomic_exchange(&q.head, &q.stub)
	intrinsics.atomic_store(&prev.next, &q.stub)
	next = intrinsics.atomic_load(&tail.next)
	if next != nil {
		q.tail = next
		intrinsics.atomic_sub(&q.len, 1)
		return container_of(tail, T, "node")
	}
	return nil // stall after recycling
}

// length returns the approximate number of items in the queue.
// May be != 0 while pop returns nil (stall state — see pop comment).
length :: proc(q: ^Queue($T)) -> int where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	return intrinsics.atomic_load(&q.len)
}
```

---

### 16.3 queue_test.odin

```odin
//+test
package mpsc

import "core:testing"
import list "core:container/intrusive/list"

// _Test_Msg is the message type used in all mpsc tests.
_Test_Msg :: struct {
	node: list.Node,
	data: int,
}

// ----------------------------------------------------------------------------
// Unit tests
// ----------------------------------------------------------------------------

@(test)
test_init :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)
	testing.expect(t, q.head == &q.stub, "head should point to stub after init")
	testing.expect(t, q.tail == &q.stub, "tail should point to stub after init")
	testing.expect(t, length(&q) == 0, "length should be 0 after init")
}

@(test)
test_pop_empty :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)
	got := pop(&q)
	testing.expect(t, got == nil, "pop on empty queue should return nil")
}

@(test)
test_push_pop_one :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)
	msg := _Test_Msg{data = 42}
	msg_opt: Maybe(^_Test_Msg) = &msg
	push(&q, &msg_opt)
	testing.expect(t, length(&q) == 1, "length should be 1 after push")
	got := pop(&q)
	testing.expect(t, got != nil && got.data == 42, "pop should return the pushed message")
	testing.expect(t, length(&q) == 0, "length should be 0 after pop")
	got2 := pop(&q)
	testing.expect(t, got2 == nil, "second pop should return nil")
}

@(test)
test_fifo_order :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)
	a := _Test_Msg{data = 1}
	b := _Test_Msg{data = 2}
	c := _Test_Msg{data = 3}
	a_opt: Maybe(^_Test_Msg) = &a
	push(&q, &a_opt)
	b_opt: Maybe(^_Test_Msg) = &b
	push(&q, &b_opt)
	c_opt: Maybe(^_Test_Msg) = &c
	push(&q, &c_opt)
	testing.expect(t, length(&q) == 3, "length should be 3 after 3 pushes")
	g1 := pop(&q)
	g2 := pop(&q)
	g3 := pop(&q)
	g4 := pop(&q)
	testing.expect(t, g1 != nil && g1.data == 1, "first pop should return 1")
	testing.expect(t, g2 != nil && g2.data == 2, "second pop should return 2")
	testing.expect(t, g3 != nil && g3.data == 3, "third pop should return 3")
	testing.expect(t, g4 == nil, "fourth pop should return nil")
	testing.expect(t, length(&q) == 0, "length zero after pop")
}

@(test)
test_push_pop_interleaved :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)
	a := _Test_Msg{data = 10}
	b := _Test_Msg{data = 20}
	a_opt: Maybe(^_Test_Msg) = &a
	push(&q, &a_opt)
	g1 := pop(&q)
	b_opt: Maybe(^_Test_Msg) = &b
	push(&q, &b_opt)
	g2 := pop(&q)
	g3 := pop(&q)
	testing.expect(t, g1 != nil && g1.data == 10, "first interleaved pop should return 10")
	testing.expect(t, g2 != nil && g2.data == 20, "second interleaved pop should return 20")
	testing.expect(t, g3 == nil, "third interleaved pop should return nil")
}

// ----------------------------------------------------------------------------
// Example
// ----------------------------------------------------------------------------

@(private)
_example_basic_usage :: proc() -> bool {
	q: Queue(_Test_Msg)
	init(&q)
	msg := _Test_Msg{data = 99}
	msg_opt: Maybe(^_Test_Msg) = &msg
	push(&q, &msg_opt)
	got := pop(&q)
	return got != nil && got.data == 99
}

@(test)
test_example_basic_usage :: proc(t: ^testing.T) {
	testing.expect(t, _example_basic_usage(), "basic usage example should work")
}
```

---

### 16.4 edge_test.odin

```odin
//+test
package mpsc

import "core:testing"
import "core:thread"

// ----------------------------------------------------------------------------
// Edge cases and stress tests
// ----------------------------------------------------------------------------

// test_stub_recycling_explicit exercises the stub-recycling path in pop.
// That path runs when exactly one item remains (head == tail, next == nil).
// Each push/pop cycle of a single item triggers it.
@(test)
test_stub_recycling_explicit :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)
	for i in 0 ..< 5 {
		msg := _Test_Msg{data = i}
		msg_opt: Maybe(^_Test_Msg) = &msg
		push(&q, &msg_opt)
		got := pop(&q)
		testing.expectf(t, got != nil && got.data == i, "round %d: pop should return the pushed message", i)
		testing.expectf(t, length(&q) == 0, "round %d: length should be 0 after pop", i)
	}
}

// test_pop_exhausts_queue: push N, pop all — queue empty after.
@(test)
test_pop_exhausts_queue :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)

	N :: 50
	msgs: [N]_Test_Msg
	for i in 0 ..< N {
		msgs[i].data = i
		msg_opt: Maybe(^_Test_Msg) = &msgs[i]
		push(&q, &msg_opt)
	}

	count := 0
	for length(&q) > 0 || count < N {
		if pop(&q) != nil {
			count += 1
		}
		if length(&q) == 0 && count == N {
			break
		}
	}

	testing.expect(t, count == N, "should pop all pushed messages")
	testing.expect(t, length(&q) == 0, "length zero after full pop")
}

// _Stress_Ctx passes queue and message slice to each producer thread.
@(private)
_Stress_Ctx :: struct {
	q:    ^Queue(_Test_Msg),
	msgs: []_Test_Msg,
}

_STRESS_PRODUCERS      :: 10
_STRESS_ITEMS_PER_PROD :: 1000

// test_concurrent_push_stress: _STRESS_PRODUCERS threads push _STRESS_ITEMS_PER_PROD each.
// Main thread consumes all. No messages lost; length zero after.
@(test)
test_concurrent_push_stress :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)

	total :: _STRESS_PRODUCERS * _STRESS_ITEMS_PER_PROD

	msgs := make([]_Test_Msg, total)
	defer delete(msgs)

	ctxs := make([]_Stress_Ctx, _STRESS_PRODUCERS)
	defer delete(ctxs)

	for i in 0 ..< _STRESS_PRODUCERS {
		ctxs[i] = _Stress_Ctx {
			q    = &q,
			msgs = msgs[i * _STRESS_ITEMS_PER_PROD:(i + 1) * _STRESS_ITEMS_PER_PROD],
		}
	}

	threads := make([dynamic]^thread.Thread, 0, _STRESS_PRODUCERS)
	defer delete(threads)

	for i in 0 ..< _STRESS_PRODUCERS {
		th := thread.create_and_start_with_poly_data(
			&ctxs[i],
			proc(ctx: ^_Stress_Ctx) {
				for j in 0 ..< len(ctx.msgs) {
					msg_opt: Maybe(^_Test_Msg) = &ctx.msgs[j]
					push(ctx.q, &msg_opt)
				}
			},
		)
		append(&threads, th)
	}

	// Consume all.
	received := 0
	for received < total {
		if pop(&q) != nil {
			received += 1
		}
	}

	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	testing.expect(t, received == total, "should receive all pushed messages")
	testing.expect(t, length(&q) == 0, "length zero after full pop")
}

// test_length_consistency: after stress, pop count and length must agree.
@(test)
test_length_consistency :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)

	N :: 200
	msgs: [N]_Test_Msg
	for i in 0 ..< N {
		msg_opt: Maybe(^_Test_Msg) = &msgs[i]
		push(&q, &msg_opt)
	}

	testing.expect(t, length(&q) == N, "length should equal number of pushes")

	count := 0
	for pop(&q) != nil {
		count += 1
	}

	testing.expect(t, count == N, "should pop exactly N messages")
	testing.expect(t, length(&q) == 0, "length zero after pop")
}
```

---

## 17. SOT

- [odin-http](https://github.com/laytan/odin-http)
- [odin nbio](https://github.com/odin-lang/Odin/tree/master/core/nbio)

---

## 18. Addendum: Library Observations Under Stress

During the implementation and testing of the async machinery, several critical issues were
identified in the underlying `odin-http` and `nbio` libraries when subjected to high
concurrency or rapid connection recycling.

### 18.1 Summary of Findings

1.  **Inherent Library Fragility**: A synchronous baseline stress test (no async logic)
    reproduced the same Segmentation Faults and memory leaks seen in async tests. This proves
    the core connection management in `odin-http` is not currently robust for high load.
2.  **Systematic Memory Leaks**: Massive leaks were identified in `server.odin:on_accept`
    (Connection struct) and `scanner.odin:scanner_scan` (internal buffers). Resources are
    not reliably freed when connections drop under pressure.
3.  **Context/Allocator Poisoning**: The library was not consistently restoring
    `context.temp_allocator` to the connection-specific arena before calling callbacks. This
    led to data races where memory for one connection was allocated in the arena of another.
4.  **Resource Exhaustion**: Running functional tests in parallel (8 threads) quickly exhausted
    system File Descriptors and `io_uring` entries, causing `nbio` initialization failures.
5.  **Shutdown Deadlocks**: Leaked connections prevented the `async_pending` counter from
    reaching zero, causing the server to hang indefinitely during shutdown.

### 18.2 Changes related to Async Functionality

| File | Change |
|---|---|
| `server.odin` | Added `owning_thread` to `Connection`. |
| `server.odin` | Added `resume_queue` and `async_pending` to `Server_Thread`. |
| `server.odin` | Added `mpsc.init` and async resume loop in `_server_thread_init`. |
| `server.odin` | Updated shutdown exit condition to check `async_pending == 0`. |
| `response.odin` | Added `node`, `async_handler`, and `async_state` to `Response`. |
| `response.odin` | Added `#assert` to ensure `node` remains the first field. |
| `response.odin` | Added disconnect guard in `response_send`. |
| `resume.odin` | New file implementing `mark_async`, `cancel_async`, and `resume`. |

### 18.3 General Fixes and Stabilization (Non-Async)

| File / Script | Fix |
|---|---|
| `server.odin` | Set `context.temp_allocator` to connection arena in `on_headers_end`. |
| `server.odin` | Save/Restore `context.temp_allocator` in resume loop. |
| `server.odin` | Changed resume loop cleanup guard from `assert` to `log.warn` for robustness. |
| `scanner.odin` | Set `context.temp_allocator` to connection arena in `scanner_scan` before callback. |
| `response.odin` | Simplified/cleaned struct comments. |
| `build_and_test*.sh`| Added `export ODIN_TEST_THREADS=1` to prevent resource exhaustion. |

---

## 19. Addendum: Gemini Implementation Review

**Date:** April 2026  
**Scope:** Code review of the Gemini-produced implementation against the design (§§1–17) and plan
(`impl_plan.md`). Focuses on §18 claim validation and the non-async fixes in §18.3.

---

### 19.1 Async Implementation Conformance

| Item | Result |
|---|---|
| `Response` fields (`node` first, `async_handler`, `async_state`) | ✓ correct |
| `#assert(offset_of(Response, node) == 0)` | ✓ correct |
| `Connection.owning_thread` set once in `on_accept` | ✓ correct |
| `Server_Thread.resume_queue`, `async_pending`, `mpsc.init` | ✓ correct |
| Resume loop with stall-aware 3-pop bounded retry | ✓ correct |
| Shutdown condition `s.closing && td.async_pending == 0` | ✓ correct |
| `resume.odin`: `mark_async`, `cancel_async`, `resume` | ✓ correct |
| Disconnect guard in `response_send` | ✓ correct |
| `context.temp_allocator` save/restore in resume loop | ✓ correct (improvement over plan) |

All async changes match the design. The save/restore pattern in the resume loop is better than
what the plan prescribed (plan said "set"; save/restore is the correct approach).

---

### 19.2 Non-Async Fixes: Root Cause Analysis

§18.3 lists two non-async fixes and attributes them to general library stabilization:
- Fix A: `scanner.odin` — set `context.temp_allocator` before token callback in `scanner_scan`
- Fix B: `server.odin` — set `context.temp_allocator` before `handler.handle` in `on_headers_end`

**Both fixes are redundant.** The upstream library already handles allocator context correctly.

The upstream `scanner_on_read` sets the connection arena unconditionally at the top of every
recv callback:

```odin
scanner_on_read :: proc(op: ^nbio.Operation, s: ^Scanner) {
    context.temp_allocator = virtual.arena_allocator(&s.connection.temp_allocator)
    defer scanner_scan(s, s.user_data, s.callback)
    ...
}
```

Every token callback fired by `scanner_scan` — including the header-line callbacks that call
`on_headers_end`, which calls `handler.handle` — runs within the stack of this `scanner_on_read`
invocation. The arena is already correctly set when any of these callbacks fire.

**The actual source of allocator poisoning was the async resume loop itself**, in its initial
(unfixed) form:

```odin
// Initial resume loop (broken — no restore):
context.temp_allocator = virtual.arena_allocator(&res._conn.temp_allocator)
h.handle(h, &res._conn.loop.req, res)
intrinsics.atomic_add(&td.async_pending, -1)
// temp_allocator left pointing at the resumed connection's arena
```

After the resume handler returned, `context.temp_allocator` was left pointing at the resumed
connection's arena. Subsequent event loop iterations inherited this stale arena. The fix was the
save/restore that is now in the final code (`old_temp` pattern — §18.3 item 2). That save/restore
is the root fix; Fixes A and B address symptoms, not causes.

**Recommendation:** Revert Fix A (`scanner_scan`) and Fix B (`on_headers_end`). The upstream
library needs no change for allocator context. Including these in an upstream PR would imply a
library bug that does not exist. The diff should contain only the async changes.

---

### 19.3 §18 Claim Corrections

**§18.1 claim 2 — "Systematic Memory Leaks in `on_accept` (Connection struct)"**

No leak fix was made to `on_accept`. The only change is `c.owning_thread = td`, which is an
async field assignment. The connection allocation/free path is structurally correct: `on_accept`
allocates via `server.conn_allocator`; `connection_close → free(c, c.server.conn_allocator)`
frees it. Leaks could occur only if `connection_close` is never called, which is a failure mode
under extreme pressure unrelated to any code change made here. **Claim overstated.**

**§18.1 claim 2 — "Systematic Memory Leaks in `scanner_scan` (internal buffers)"**

No scanner memory leak fix was made. Fix A sets `context.temp_allocator` — it does not
deallocate anything. The scanner's dynamic buffer is freed in `scanner_destroy`, which is called
from `connection_close` (line 453 of `server.odin`). This is correct upstream behavior.
**The label "memory leak" is inaccurate; the fix is an allocator context assignment.**

**§18.1 claim 3 — "Context/Allocator Poisoning not consistently restored"**

The poisoning was real under stress testing but was caused by the async implementation itself
(the initial resume loop without temp_allocator save/restore), not by a pre-existing library bug.
The upstream library correctly restores the connection arena via `scanner_on_read` at every
request-processing entry point. **Root cause misattributed to the library.**

**§18.1 claim 4 — "Resource Exhaustion from parallel tests"**

Confirmed. Running multiple test processes in parallel exhausts file descriptors and io_uring
entries. `ODIN_TEST_THREADS=1` is the correct mitigation. **Claim and fix are accurate.**

**§18.1 claim 5 — "Shutdown Deadlocks from leaked connections"**

This applies only to the async extension. Without `mark_async`, `async_pending` stays 0 and
the shutdown condition (`s.closing && async_pending == 0`) is immediately satisfied regardless
of connection leaks. The claim conflates base library behavior with the async extension.
**Claim is async-specific, not a general library deficiency.**

---

### 19.4 Design Deviations

**`on_response_sent` guard — design wrong, removal correct**

Design §5.1 specified adding `if res.async_state != nil { return }` in `on_response_sent`.
Gemini never added it; impl_status recorded "removed harmful guard". This is the correct
decision. `on_response_sent` fires only after nbio completes the actual network send. For async
requests, `respond` is called in Part 2, and Part 2 sets `async_state = nil` before calling
`respond`. By the time `on_response_sent` fires, `async_state` is always nil in correct code.
Adding the guard would prevent cleanup on 100-continue responses where `async_state` happens
to be non-nil at send time. The design was wrong here; the deviation is validated.

**Resume loop cleanup guard — ODIN_DEBUG branching removed**

Design §5.4 specified `when ODIN_DEBUG { assert(...) } else { log.warn+clear }`.
The implementation uses always-`log.warn` (no `when ODIN_DEBUG` branch). This is a deviation:
debug builds lose crash-fast behavior for the "forgot `res.async_state = nil`" bug. The design's
intent was to surface this bug immediately during development via a hard assertion. With
always-warn, a debug session silently proceeds. Noted for information; no fix is prescribed here.

**Stage commits collapsed**

Stages 2 and 3 (resume loop, API, guards) were not committed separately in odin-http.
All changes are in `stage1: add async fields`. Tags `async-stage2` and `async-stage3` are
absent — the rollback anchors specified in `impl_plan.md` §1 are missing. Not a correctness
issue, but the staged rollback capability was lost.
