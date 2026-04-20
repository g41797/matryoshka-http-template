# Odin-HTTP Async Handlers for Dummies

**Version 3.0**

---

### Hello!

Short sentences. Simple examples.

After reading this, you will know how async handlers work.

---

### 1. What is a Handler?

A handler is a small function that answers a web request.

Old simple version (synchronous):

```odin
my_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
    http.respond_plain(res, "Hello!")
}
```

---

### 2. The New Async Way

With async handlers the function is **split into two parts**:

- **Part 1** (first call) – very fast, runs on the io thread
- **Background work** – does the slow/heavy work
- **Part 2** (resume call) – runs again on the io thread to send the final answer

The flow is **broken on purpose** so the io thread stays free.

---

### 3. Visual Diagram – How the Flow Really Works

```text
Customer request arrives
          │
          ▼
   Handler Part 1 (io thread)          ← very fast
          │
          ├── http.mark_async(...)
          ├── start background work
          └── return immediately       ← io thread is free again!
          │
          ▼
   Background work (pipeline / queue)
          │
          └── does slow work (...)
          │
          └── sends result via pipeline infrastructure
			└── for http flow it calls http.resume(res)
			│
          	▼
   Handler Part 2 (resume call on io thread)
          │
          └── send final answer to customer
          └── clean up
```

---

### 4. Real Simple Example with Background Thread

Copy this code. It is the simplest real async handler you can write.

```odin
package my_app

import http "vendor/odin-http"
import "core:thread"

My_Work :: struct {
    thread: ^thread.Thread,
    result: string,
}

background_proc :: proc(t: ^thread.Thread) {
    res := (^http.Response)(t.data)
    work := (^My_Work)(res.async_state)

    // Store the result BEFORE calling resume.
    // After resume returns, the io thread owns res — do not touch it.
    work.result = "Hello from background thread!"
    http.resume(res)
}

my_async_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {

    if res.async_state == nil {
        // ── PART 1: First call (very fast) ─────────────────────────────
        // Use context.temp_allocator — safe here because only the io thread allocates.
        // Memory stays alive until after Part 2 responds.
        work := new(My_Work, context.temp_allocator)

        // Safe order: prepare → mark_async → start work.
        // Always pass h so resume goes back to the right handler (middleware-safe).
        http.mark_async(h, res, work)

        t := thread.create(background_proc)
        if t == nil {
            // Rule 1: if background work fails to start, BOTH steps are required.
            // Step 1: cancel_async — rolls back state and fixes the pending counter.
            //         Without this, the server will never shut down cleanly.
            // Step 2: respond with error — without this the client waits forever.
            http.cancel_async(res)
            http.respond(res, .Internal_Server_Error)
            return
        }
        t.data = res
        work.thread = t
        thread.start(t)

        return  // ← MUST return immediately — do not do any slow work here
    }

    // ── PART 2: Resume call ─────────────────────────────────────────────
    work := (^My_Work)(res.async_state)

    // defer runs before the function returns, after respond is enqueued.
    // This guarantees cleanup even if an error happens.
    defer {
        thread.join(work.thread)   // background thread already finished — just releases the handle
        thread.destroy(work.thread)
        res.async_state = nil      // required: tells the server the async cycle is finished
    }

    http.respond_plain(res, work.result)
}
```

Register it normally:

```odin
http.route_get(router, "/async", http.handler(my_async_handler))
```

---

### 5. Simple Example — Limitations

The example above is simplified for learning only.
It creates one OS thread per request and calls `http.resume` directly from the background thread.
This works for learning but is not the production pattern.

Once the example works for you, read `async-handlers-for-advanced.md` for the production approach.

---

### 6. Next Steps

1. Copy the example from section 4 and run it.
2. Once it works, read `async-handlers-for-advanced.md` to learn the production pattern.
3. Later learn how to read the request body with `http.body()`.

The “broken chain” is the key idea that makes your server fast.

---

### 7. Error Handling

There are two places where things can go wrong.

---

**Problem 1 — Background work fails to start (Part 1)**

For example: `thread.create` returns `nil`, or your pipeline queue is full.

You MUST do both of these things:

```
1. http.cancel_async(res)            ← undo the mark_async call
2. http.respond(res, .Internal_Server_Error)  ← tell the client something went wrong
```

If you skip step 1: the server's pending counter (`async_pending`) stays wrong. Here is why:
`mark_async` increments this counter. `cancel_async` and the completion of Part 2 decrement it.
The server's shutdown loop waits until the counter reaches zero before exiting. If `cancel_async`
is missing, the counter never reaches zero — the shutdown loop runs forever. The server hangs.

If you skip step 2: the client waits forever. The request is lost silently.

The example in section 4 already shows this pattern.

---

**Problem 2 — Background work fails during processing**

Your background thread ran, but the work itself failed (database error, timeout, etc.).

The design does not tell you exactly how to handle this. You decide.

Simple advice:
- Add an `ok: bool` or `err: string` field to your `My_Work` struct.
- Before calling `http.resume(res)`, set `work.ok = false` and fill in the error.
- In Part 2, check `work.ok` and respond with the right HTTP status (e.g. `.Internal_Server_Error`, `.Bad_Gateway`, etc.) and log the error.

The examples in this guide do not show Part 2 error handling to keep the code simple.
In a real project you should always handle it.

---

**Links**
- [odin-http GitHub](https://github.com/laytan/odin-http)
- [Odin nbio](https://github.com/odin-lang/Odin/tree/master/core/nbio)

---

### 8. Hard Rules

These are not suggestions. Breaking any of them causes bugs that are hard to find.

---

**Ownership — who owns what and when:**

| Phase | Owner | Background thread may |
|-------|-------|-----------------------|
| Part 1 (first call, io thread) | IO thread | — |
| Background work | Background thread (limited) | ONLY: read/write `work` struct fields; call `http.resume(res)` exactly once |
| Part 2 (resume call, io thread) | IO thread | — |

In the background phase: do not read or write any `res` field directly. Do not call any
`http.*` proc except `http.resume`. Do not use the connection's allocator.

---

**Rule 1 — `http.resume(res)` must be called exactly once.**

- Zero calls: the request is permanently lost. The client waits forever. The server never shuts down.
- Two calls: the response is sent twice. Undefined behavior — likely a crash or corrupted connection.

---

**Rule 2 — `mark_async` must be called BEFORE starting background work.**

Wrong order:
```odin
thread.start(t)         // ← wrong: background may call resume before mark_async
http.mark_async(...)    // ← too late
```

If `resume` is called before `mark_async`, the counter is incremented after the decrement.
The counter stays permanently above zero. The server never shuts down.

Correct order:
```odin
http.mark_async(h, res, work)   // ← always first
thread.start(t)                  // ← then start work
```

---

**Rule 3 — Background thread must not allocate memory.**

Only read and write fields of the `work` struct that were set up in Part 1.
Do not call anything that allocates (e.g. `append`, `make`, `fmt.tprintf`) from the background thread.

---

**Rule 4 — `res.async_state = nil` before Part 2 returns.**

The server uses this field to track the async cycle. If it is non-nil when Part 2 returns,
the server cannot safely reset the connection for the next request.

The example uses `defer` to guarantee this:
```odin
defer {
    res.async_state = nil   // mandatory — without this, the server cannot reset the connection
    ...
}
```

---

**Rule 5 — Part 2 runs even if the client disconnected. Always clean up.**

The client may disconnect while your background work is running.
Part 2 WILL still be called — the server requires it for cleanup.
Do not skip cleanup based on connection state.
Always join the thread and free the work struct in Part 2, regardless.

---

### Ready for more?

Read `async-handlers-for-advanced.md` — production patterns, pipeline integration,
allocator strategy, and middleware awareness.
