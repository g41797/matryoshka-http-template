# Odin-HTTP Async Handlers for Advanced Developers

**Version 1.0**

---

### 1. Quick Recap — Why Async Matters

In odin-http the io threads (the ones running `nbio.tick()`) are precious.
If your handler does slow work (database call, file read, external API, heavy calculation),
it blocks the whole thread. Other requests on the same thread wait.

Async handlers fix this:
- Part 1 (first call) is fast — starts the work and returns immediately.
- Background work runs somewhere else.
- Part 2 (resume call) runs later on the io thread and sends the answer.

The chain is **intentionally broken**. This is the whole point.

---

### 2. The Teaching Example vs Real Production

The example in the Dummies guide (background thread calling `http.resume(res)` directly)
is **only for learning**.

It is simple and shows the flow clearly, but it has two problems in real life:

1. It creates one OS thread per request — this does **not** scale.
2. The background code knows about `http.Response` and calls `http.resume` directly —
   this mixes the HTTP layer with business logic.

**In real production you should do it differently.**

---

### 3. Recommended Production Pattern

```text
HTTP io thread (Part 1)
    │
    ├── http.mark_async(h, res, work)   ← record state, increment pending counter
    ├── send request to pipeline inbox  ← mailbox, channel, or queue
    └── return immediately              ← io thread is free

Pipeline / Worker pool (background)
    │
    └── receive message from inbox
    └── do real work
    └── store final result in work struct
    └── call http.resume(res)           ← pipeline glue code calls this
            │
            ├── mpsc.push(res) to resume_queue
            └── nbio.wake_up(io_thread)

HTTP io thread (Part 2, next tick)
    │
    └── resume loop dequeues res
    └── re-invokes handler (Part 2 branch)
    └── read result from work struct
    └── send final HTTP response
    └── clean up
```

Key points:

- The **pipeline** (job queue, worker pool) does **not** touch `res` fields
  directly. It only prepares data and stores the result in the `work` struct.
- When the work is done, the **pipeline glue code** calls `http.resume(res)`. This pushes
  `res` onto the MPSC queue and wakes the io thread.
- The **odin-http resume loop** dequeues `res` on the next tick and re-invokes the handler.
  It does not call `http.resume` — that is the pipeline's job.
- This keeps HTTP code separate from business logic — easier to test and maintain.

You (the designer) decide how much the background code knows about HTTP.
The cleanest way: background code knows nothing about HTTP. Only the glue layer calls `http.resume`.

---

### 4. Real-World Example Sketch (Matryoshka Style)

```odin
// Part 1 — inside your HTTP handler (io thread)
my_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
    ctx := (^My_Context)(h.user_data)

    if res.async_state == nil {
        work := new(My_Work, ctx.alloc)
        work.request_data = copy_request_data(req, ctx.alloc)  // copy what pipeline needs

        // Safe order: mark_async BEFORE sending to pipeline.
        http.mark_async(h, res, work)

        // Send to pipeline — no thread.create needed.
        msg := Work_Message{res = res, work = work}
        matryoshka.mbox_send(ctx.pipeline_inbox, &msg)

        return  // io thread is free
    }

    // Part 2 — resume call (io thread)
    work := (^My_Work)(res.async_state)
    defer {
        free_work(work, ctx.alloc)
        res.async_state = nil  // mandatory
    }

    if !work.ok {
        http.respond(res, .Internal_Server_Error)
        return
    }
    http.respond_plain(res, work.result)
}
```

The pipeline worker receives the message, does the heavy work, stores the result in
`work.result`, and then — through the pipeline's reply infrastructure — the glue code calls
`http.resume(res)`. The odin-http resume loop dequeues `res` on the next tick and re-invokes
the handler at Part 2.

---

### 5. Allocator Strategy

**In the simple example** `context.temp_allocator` (the per-connection arena) is used.
This is safe only because the background thread never allocates — it only reads and writes
fields of the already-allocated `work` struct.

**In real production** use this pattern instead:

- Put your allocator in `handler.user_data` (a `My_Context` struct set at route registration).
- Allocate the `work` struct from that allocator in Part 1.
- Pass the allocator in the pipeline message so the worker can use it if needed.
- Free everything in Part 2.

This keeps the allocator lifetime independent of the HTTP connection.
Never allocate from `context.temp_allocator` inside the background thread — the arena is
not thread-safe. Any such allocation is a data race.

---

### 6. Middleware Awareness

If your async handler sits inside a middleware chain, be aware:

Any code in a middleware wrapper that runs **after** `h.next.handle(h.next, req, res)` returns
executes at Part 1 unwind time — **before** background work starts and before the response
is built. Specifically:

- Timing middleware: measures near-zero elapsed time (Part 1 is instantaneous).
- Response-status logging: `res.status` has not been set yet.
- `defer` cleanup in middleware: runs before the background thread has finished — must not
  free resources the background thread or Part 2 will read.

For async-aware middleware, check `res.async_state != nil` on return and skip
post-processing for async handlers.

---

### 7. Hard Rules

These are not suggestions. Breaking any of them causes bugs that are hard to find.

**Rule 1** — `http.mark_async` must be called **before** sending work to the pipeline.
If the pipeline calls `http.resume` before `mark_async` completes, the pending counter
is incremented after the decrement — the server never shuts down.

**Rule 2** — `http.resume(res)` must be called **exactly once**.
- Zero calls: the request is permanently lost; the client waits forever; server never shuts down.
- Two calls: undefined behavior — likely a crash or corrupted connection.
- If multiple pipeline workers could complete the same request (race in a worker pool), use
  coordination (mutex, atomic flag, or single-owner handoff) to guarantee exactly one worker
  calls `http.resume`. Pass `^Response` as a single-owner token — one queue, one receiver.

**Rule 3** — In Part 2 you **must** set `res.async_state = nil` before returning.
Use `defer { res.async_state = nil }` at the top of the resume branch.

**Rule 4** — Background code must not allocate from `context.temp_allocator`.
The per-connection arena is not thread-safe. Any allocation from a background thread is a
data race.

**Rule 5** — Part 2 runs even if the client disconnected. Always clean up.
The server requires Part 2 for cleanup regardless of connection state.

**Rule 6** — If background work fails to start, call **both** `http.cancel_async(res)` and
`http.respond`. Missing either one hangs the server or the client.

---

### 8. Production Checklist

Before you ship:

- [ ] Use a real worker pool or pipeline instead of `thread.create` per request
- [ ] Background code does **not** read or write `res` fields directly
- [ ] Only the pipeline glue code calls `http.resume(res)` — exactly once
- [ ] Allocator comes from `handler.user_data`, not `context.temp_allocator`
- [ ] All Part 1 failure paths call both `cancel_async` and `http.respond`
- [ ] `res.async_state = nil` is guaranteed in Part 2 (use `defer`)
- [ ] Middleware post-processing is async-aware (see §6)
- [ ] Test graceful shutdown with pending async requests
- [ ] Test client disconnect during async work

---

### 9. Next Steps

1. Start with the simple example from the Dummies guide.
2. Once it works, refactor to the production pattern above (§3–§4).
3. Connect to your real pipeline (Matryoshka or your own queue).
4. Add shutdown and disconnect tests (see `impl_plan.md` Stage 4).

---

**See also**
- `async-handlers-for-dummies.md` — beginner guide with the teaching example
- `async-handlers.md` — full design document (API reference, MPSC queue, edge cases)
- `impl_plan.md` — implementation stages and test suite
- [odin-http GitHub](https://github.com/laytan/odin-http)
- [Odin nbio](https://github.com/odin-lang/Odin/tree/master/core/nbio)
