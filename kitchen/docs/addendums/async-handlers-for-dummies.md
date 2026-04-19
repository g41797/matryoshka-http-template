# Odin-HTTP Async Handlers for Dummies

**Version 2.9**

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
			└── for hhtp flow it calls http.resume(res)
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
        // Use context.temp_allocator — the per-connection arena.
        // It is safe here because only the io thread uses the allocator.
        // The arena stays alive until after Part 2 responds.
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

### 5. For Advanced Users – Important Real-World Note

The example above is **simplified for learning only**.

In the simple example the background thread calls `http.resume(res)` directly.
This is only to make the “broken chain” easy to see.

**In real production you usually do it differently:**

- The background work (Matryoshka pipeline, job queue, worker pool, etc.) **does not** know about `http.Request` or `http.Response`.
- It only prepares the final result data and stores it in the `work` struct (`res.async_state` points to it) **before** the pipeline calls `resume`.
- When the work is finished, the pipeline infrastructure calls `http.resume(res)` **on behalf of** the completed work.
- Then the handler’s Part 2 (resume call) runs automatically on the io thread.

This is the recommended way.
The HTTP layer stays separate from the business logic / pipeline.

However, this is **not forced**.
You (the designer) can decide how much the background code knows about HTTP.
For small projects the simple example style is fine.

**Allocators in real projects:** the example uses `context.temp_allocator` (the per-connection
arena). In a real project with a Matryoshka pipeline or shared worker pool, get the allocator
from `handler.user_data` — a `My_Context` struct set at route registration. This keeps the
allocator lifetime independent of the connection.

---

### 6. Next Steps

1. Copy the example from section 4 and run it.
2. Once it works, try moving the `http.resume` call out of the background thread (as described in the advanced section).
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

If you skip step 1: the server's pending counter stays wrong. The server will never shut down cleanly.

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
