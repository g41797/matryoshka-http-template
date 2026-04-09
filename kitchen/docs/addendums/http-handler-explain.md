**`odin-http` (laytan/odin-http) is a pure-Odin HTTP/1.1 server (and client) library that **  implements a **modern multi-threaded, event-driven architecture** built on Odin’s `core:nbio` (non-blocking I/O). It uses platform-native async primitives (io_uring on Linux, kqueue on macOS, IOCP on Windows) while still exposing a simple synchronous-looking `proc(req: ^Request, res: ^Response)` handler API.

This is exactly the “Reactor + thread-per-core” pattern used by high-performance servers today. Below is a detailed breakdown of its implementation based on the current source (as of the latest main branch).

### 1. Overall Architecture

- **Multi-threaded event loops** (not a single-threaded reactor, not a classic thread pool).
  The `Server` struct spawns `thread_count` worker threads (default = number of CPU cores – 1). Each thread owns its own `nbio.Event_Loop`.

- **Per-thread state** (`Server_Thread`):
  - Private `nbio.Event_Loop`
  - Map of active connections owned by this thread
  - One pending `nbio.accept_poly` operation on the shared listening socket

- **Connection ownership**: The kernel load-balances incoming connections across the listening threads. The thread that accepts a connection owns it for its entire lifetime (no work-stealing between threads).

- **No per-connection OS thread** — everything runs on the small fixed pool of worker threads.

### 2. The Request → Handler → Response Pipeline

Here is the exact flow (simplified from `server.odin`, `response.odin`, `handlers.odin`, and supporting files):

1. **Accept** (async via `nbio`):
   - Every worker thread posts an `nbio.accept_poly` on the same `TCP_Socket`.
   - `on_accept` callback fires → new `net.TCP_Socket` is obtained.
   - A `Connection` struct is allocated (with its own temp arena allocator) and added to the thread’s connection map.

2. **Request parsing** (incremental, non-blocking, state-machine driven):
   - `conn_handle_reqs` sets up a `bufio.Scanner` + virtual arena.
   - A chain of callbacks (`on_rline1` → `on_rline2` → `on_header_line` → `on_headers_end`) parses:
     - Request line
     - Headers (with configurable limits)
     - (Body handling is optional and async — see below)
   - All reads are driven by `nbio` under the hood; the thread never blocks on `recv`. Parsing uses Odin’s `bufio.Scanner` with callbacks that advance the state machine.

3. **Handler invocation** (`proc(req, res)`):
   - Once headers are parsed (`on_headers_end`), the library calls the user-provided `Handler` synchronously on the current worker thread:
     ```odin
     l.conn.server.handler.handle(&l.conn.server.handler, &l.req, &l.res)
     ```
   - The `Handler` type is a thin wrapper (see `handlers.odin`):
     ```odin
     Handler :: struct { user_data: rawptr, next: Maybe(^Handler), handle: Handler_Proc }
     ```
     - `http.handler(your_proc)` simply stores your `proc(req, res)` in `user_data` and creates a closure that calls it.
     - Routing (in `routing.odin`, not shown here) builds a chain of handlers (`next` field) for middleware + route matching (Lua-style patterns).

   - **Important**: The handler runs **synchronously** on the worker thread that accepted the connection. It blocks that thread until it returns (or until it initiates an async operation like `http.body`).

4. **Response assembly & send** (non-blocking):
   - Inside the handler you call helpers like `respond_plain`, `respond_json`, `respond_file`, etc.
   - These fill a `Response` struct that buffers **everything** (status line + headers + body) into an internal `bytes.Buffer`.
   - After the handler returns, `response_send` (or equivalent) is called:
     - `nbio.send_poly(socket, full_buffer, conn, on_response_sent)`
   - The send is fully asynchronous. When complete, `on_response_sent` callback:
     - Cleans up the request loop
     - Prepares the connection for the next request (HTTP/1.1 keep-alive) or closes it.

5. **Body handling (POST/PUT etc.)**:
   - If your handler needs the request body, you call `http.body(req, max_size, res, callback)`.
   - This registers an async read operation; your handler can return immediately.
   - The callback receives the body (or error) and is responsible for sending the final response.
   - This is how the library gives you an “async escape hatch” without forcing the entire API to be callback-based.

### 3. How This Addresses (or Doesn’t) the “Waste & Coupling” You Mentioned

- **Resource efficiency**:
  - Only a handful of OS threads (≈ #cores), each running a tight `nbio.tick()` event loop.
  - Thousands of connections per thread are possible because I/O never blocks the thread.
  - Per-connection memory is low (temp arena + scanner state).

- **Decoupling**:
  - The handler `proc` is no longer tied to a dedicated thread for the entire request lifetime. I/O (accept/read/write) is purely async.
  - However, **the proc itself still runs synchronously** on one of the worker threads. If your handler does heavy CPU work or blocking calls (DB query without async wrapper, long computation), it stalls that thread’s event loop until it returns. This is the remaining “coupling” you noticed.

- **Comparison to the old model you described**:
  | Aspect                  | Old thread-pool model                  | odin-http (current)                          |
  |-------------------------|----------------------------------------|----------------------------------------------|
  | Threads                 | One per request (or large pool)       | Fixed #cores threads + event loops           |
  | I/O                     | Blocking `recv`/`send`                | Non-blocking via `nbio` (io_uring etc.)     |
  | Handler execution       | Runs on its own thread until done     | Runs synchronously on accepting thread       |
  | Keep-alive / pipelining | Expensive (thread stays busy)         | Cheap (same thread re-uses connection)      |
  | Scaling limit           | Thread overhead                       | Event-loop + handler CPU time                |

### 4. Practical Implications for You

- **If your handlers are mostly I/O-bound** (DB, upstream calls, file reads) → this is excellent. You use `http.body`, async file APIs, or wrap external calls in `nbio` yourself and the thread stays free.
- **If your handlers are CPU-heavy** → you may still see contention on the small thread pool. In that case you would offload work to a separate worker pool (Odin’s `core:thread` or a job queue).
- **Performance focus**: The library is explicitly tuned for Linux + io_uring. Benchmarks are in the `comparisons/` directory.

In short, `odin-http` is a **solid modern implementation** for Odin: it gives you the ergonomic `request → proc → response` API you like while using a high-performance event-driven core under the hood. The only remaining “waste/coupling” is the synchronous nature of the handler proc itself — exactly the trade-off most high-performance frameworks make (Nginx workers, Go’s net/http goroutines, Actix, etc.). If you want fully async handlers (coroutine style), you would need to build your own layer on top of the raw `nbio` operations or wait for future Odin language features.

The code is still marked “beta” and actively evolving (recent shift from custom `old_nbio` to `core:nbio`), so check the repo for the absolute latest. If you want me to dive deeper into any specific file (e.g., `scanner.odin` for the exact parsing state machine or `routing.odin`), just say the word!

## Handlers

**This is Odin code** for a lightweight HTTP middleware system (in `package http`). It defines reusable **handlers** and **middleware**, with a focus on a simple **IP-based rate limiter**.

I'll break it down section by section, explaining what each part does, how it works, and why it's written the way it is. Odin is a systems language (C-like but with better ergonomics), so it uses explicit pointers, manual memory management, and `proc` types for callbacks.

### 1. Type Aliases for Handlers

```odin
Handler_Proc :: proc(handler: ^Handler, req: ^Request, res: ^Response)
Handle_Proc :: proc(req: ^Request, res: ^Response)
```

- `Handler_Proc` is the **full middleware signature**: it receives the current handler (so it can call the next one).
- `Handle_Proc` is the **simple handler signature** (no `handler` pointer). This is what most users write.

### 2. The `Handler` Struct (the core building block)

```odin
Handler :: struct {
    user_data: rawptr,
    next: Maybe(^Handler),        // nil or another Handler
    handle: Handler_Proc,
}
```

This is how **every handler and middleware** is represented.
- `user_data` stores arbitrary data (cast back later).
- `next` enables **middleware chaining** (like Express.js).
- `handle` is the function that actually runs.

### 3. Creating a Simple Handler

```odin
handler :: proc(handle: Handle_Proc) -> Handler { ... }
```

This is a **convenience constructor**.
You give it a normal `Handle_Proc` (the one without the `handler` param), and it wraps it into a full `Handler` by storing the proc in `user_data` and creating a tiny adapter that calls it.

### 4. Creating Middleware

```odin
middleware_proc :: proc(next: Maybe(^Handler), handle: Handler_Proc) -> Handler { ... }
```

This builds a **middleware layer**.
It takes the **next** handler in the chain and a `Handler_Proc` that knows how to call the next one when it's done.

### 5. Rate-Limiting Support Types

```odin
Rate_Limit_On_Limit :: struct { ... }          // custom "rate limit hit" behavior
rate_limit_message :: proc(...) -> Rate_Limit_On_Limit { ... }  // helper to send a message
Rate_Limit_Opts :: struct { ... }              // configuration
Rate_Limit_Data :: struct { ... }              // internal state (map + mutex + timer)
```

- `Rate_Limit_On_Limit` lets you customize what happens when someone is rate-limited (default is just `429 Too Many Requests`).
- `rate_limit_message` is a quick way to return a custom error body.
- `Rate_Limit_Opts` holds:
  - `window`: how long each "bucket" lasts (e.g. 1 minute).
  - `max`: max requests per IP in that window.
  - `on_limit`: optional custom response handler.

`Rate_Limit_Data` is the **runtime state**:
- `hits` map: IP → request count.
- `next_sweep`: when the window resets.
- `mu`: mutex for thread safety (Odin web servers are usually multi-threaded).

### 6. The Actual Rate Limiter (`rate_limit`)

This is the biggest and most interesting function. Here's what it does:

```odin
rate_limit :: proc(data: ^Rate_Limit_Data, next: ^Handler, opts: ^Rate_Limit_Opts, ...) -> Handler
```

**How it works step-by-step** (inside the `h.handle` closure):

1. **Lock** the mutex (thread-safe).
2. **Sweep / Reset** the hit counter if the time window has expired:
   ```odin
   if time.since(data.next_sweep) > 0 {
       clear(&data.hits)
       data.next_sweep = time.time_add(time.now(), data.opts.window)
   }
   ```
   This is a **fixed window** rate limiter (simple, not sliding-window-per-request).

3. **Count the request** for this client's IP:
   ```odin
   hits := data.hits[req.client.address]
   data.hits[req.client.address] = hits + 1
   ```

4. **Unlock** the mutex.

5. **If over the limit**:
   - Set status `429 Too Many Requests`.
   - Calculate how many seconds until the window resets and add `Retry-After` header.
   - Call the custom `on_limit` handler (if provided) or just `respond(res)`.

6. **Otherwise**, call the **next** handler in the chain:
   ```odin
   next := h.next.(^Handler)
   next.handle(next, req, res)
   ```

### Summary – How You Would Use It

```odin
// Example usage (not in the snippet)
opts := Rate_Limit_Opts{
    window = 60 * time.Second,
    max    = 100,
    // on_limit = rate_limit_message(&"Slow down!")
}

rate_limit_data: Rate_Limit_Data
defer rate_limit_destroy(&rate_limit_data)

my_rate_limiter := rate_limit(&rate_limit_data, &my_next_handler, &opts)

// Then chain it:
server_handler := middleware_proc(my_rate_limiter, some_other_middleware)
```
**Yes — exactly.**

The simple `http.handler(proc(req, res) { … })` is just a convenience wrapper that only gives you `req` and `res`.
If your handler needs **any extra data** (a database connection, configuration, a counter, user session info, etc.), you must use the **full `Handler`** API instead of the convenience `http.handler`.

### How to pass extra information to a handler

Here’s the cleanest pattern (copy-paste ready):

```odin
// 1. Define your own data struct (can contain anything)
MyHandlerData :: struct {
    secret_key: string,
    db: ^MyDatabase,           // or whatever you need
    request_count: int,        // example of mutable state
    // ... anything else
}

// 2. Write the handler using the FULL signature (Handler_Proc)
my_custom_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
    data := cast(^MyHandlerData)(h.user_data)   // ← this is how you get your extra data

    data.request_count += 1   // you can mutate it safely

    fmt.printf("secret = %s, request #%d\n", data.secret_key, data.request_count)

    // now do whatever you want with req/res + your data
    http.respond_plain(res, fmt.tprintf("Hello! count = %d", data.request_count))
}

// 3. In your serve() function, create the handler like this:
serve :: proc() {
    // ... router init ...

    my_data := MyHandlerData{
        secret_key = "super-secret-123",
        db = &my_global_db,
        // ...
    }

    custom_handler := http.Handler{
        user_data = &my_data,           // ← your extra data goes here
        next      = nil,                // this is a leaf handler (no "next")
        handle    = my_custom_handler,  // the proc you defined above
    }

    http.route_get(&router, "/custom", custom_handler)

    // ... rest of your routes ...
}
```

### Alternative: If you prefer the middleware style

You can also do it with `middleware_proc` even for a final handler (just leave `next` empty):

```odin
my_handler_with_data := http.middleware_proc(
    nil,  // no next handler
    proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
        data := cast(^MyHandlerData)(h.user_data)
        // ... same as above
        http.respond_plain(res, "done")
    },
)

// Then assign the data before registering
my_handler_with_data.user_data = &my_data
http.route_get(&router, "/custom", my_handler_with_data)
```

### Why this design?

The `http` package uses the same pattern as the rate limiter you saw earlier:
- `user_data: rawptr` is the official way to carry arbitrary context.
- The convenience `http.handler()` only exists for the 90 % of cases where you only need `req` + `res`.
- Everything else (middleware, rate limiting, auth, etc.) uses the full `Handler` struct.

### Bonus tips

- If your data needs to be cleaned up when the server shuts down, store the pointer in a slice or struct and call a destroy function in a `defer` (like `rate_limit_destroy`).
- You can share the **same** `MyHandlerData` across many routes if you want (just point multiple handlers at the same pointer).
- For very simple cases you can also capture variables with a local proc:

  ```odin
  counter := 0
  my_handler := http.handler(proc(req: ^http.Request, res: ^http.Response) {
      counter += 1   // this works because the proc is defined inside serve()
      http.respond_plain(res, fmt.tprintf("count = %d", counter))
  })
  ```

  But this only works for **very small** things that live on the stack for the whole lifetime of the server. The `user_data` way is the official, recommended approach.


# Odin-HTTP Handler Lifecycle Analysis

**Author**: Systems Architect (Odin + multithreading expert)
**Target**: `laytan/odin-http` (main branch as of April 2026)
**Scope**: Full analysis of the `http.Handler` type lifecycle — creation, allocation, usage, destruction, multi-threading semantics, allocator usage, pitfalls, and recommended idioms.

This document is self-contained and ready for direct copy-paste.

---

## 1. Handler Definition & Core Types (`handlers.odin`)

```odin
Handler_Proc :: proc(handler: ^Handler, req: ^Request, res: ^Response)
Handle_Proc  :: proc(req: ^Request, res: ^Response)

Handler :: struct {
    user_data: rawptr,
    next:      Maybe(^Handler),
    handle:    Handler_Proc,
}
```

- **Value type** (not a pointer). Small struct (rawptr + tagged union + procedure pointer).
- The `handle` field is the actual entry point called by the server.
- `next` enables middleware chaining (middleware wraps another handler).
- `user_data` is the opaque payload for state (cast back inside the closure).

---

## 2. Creation / Allocation

### 2.1 Simple Handler (`http.handler`)
```odin
handler :: proc(handle: Handle_Proc) -> Handler { ... }
```
- Returns **by value** (stack copy in caller scope).
- Internally:
  - Stores the user `Handle_Proc` pointer in `user_data`.
  - Creates a thin closure `proc(h: ^Handler, req, res)` that casts `user_data` back and calls the original proc.
- **No heap allocation** for the `Handler` itself.
- Allocation cost: zero (pure value).

### 2.2 Middleware / Chaining (`middleware_proc`, `rate_limit`)
- `middleware_proc(next, handle)` returns a new `Handler` (value) with `next` set.
- `rate_limit`:
  - Allocates `^Rate_Limit_Data` on the **passed allocator**.
  - Inside: `make(map[net.Address]int, 16, allocator)` + `sync.Mutex`.
  - Stores pointer to that data in `user_data`.
  - Provides `rate_limit_destroy` (must be called manually).

### 2.3 Router Integration (`routing.odin`)
```odin
Router :: struct { ... routes: map[Method][dynamic]Route, all: [dynamic]Route ... }
Route :: struct { handler: Handler, pattern: string }
```
- `router_init(router, allocator)` — allocates the maps and dynamic arrays using the provided allocator.
- Each `route_get`/`route_post`/… does:
  - `strings.concatenate(...)` (allocates pattern string on router allocator).
  - Stores **copy** of the `Handler` struct inside the `Route`.
- `router_handler(router)` returns a top-level `Handler` (value) whose `handle` proc dispatches to the matching route’s `handler.handle`.

**Server attachment** (`server.odin: serve`):
```odin
s.handler = h   // struct copy into Server
```
The `Server.handler` lives for the entire server lifetime and is **shared across all threads**.

---

## 3. Usage (Per-Request Flow)

### 3.1 Call Site (`server.odin`)
1. `on_accept` → `new(Connection, server.conn_allocator)`
2. `conn_handle_reqs` → sets up per-connection `virtual.Arena` (temp allocator) + `Scanner`.
3. Parsing state machine (`on_rline*` → `on_header_line` → `on_headers_end`).
4. In `on_headers_end` (after validation, Expect: 100-continue, etc.):
   ```odin
   // (exact line not shown in partial but inferred from architecture)
   server.handler.handle(&server.handler, &l.req, &l.res)
   ```
   - If router: `router_handler.handle` → `routes_try` → matching `route.handler.handle`.
   - If simple handler: directly calls user `Handle_Proc`.

**Execution context**:
- Runs **synchronously** on the worker thread that owns the connection (`td` thread-local).
- Blocks the event loop thread until the handler returns (unless async body read via `http.body`).
- `req` / `res` live on the per-connection `Loop` (reused for keep-alive).

---

## 4. Destruction / Deallocation

- **Handler struct itself**: Never explicitly freed. It lives in:
  - `Server.handler` (server lifetime)
  - `Router` routes (until `router_destroy`)
- **User-managed data**:
  - `rate_limit_destroy(data)` — locks, `delete(data.hits)`, frees map.
  - `router_destroy(router)` — deletes all pattern strings + maps + dynamic arrays.
- **Per-connection cleanup** (`connection_close`):
  - `virtual.arena_destroy(&c.temp_allocator)`
  - `scanner_destroy`
  - `free(c, conn_allocator)`
  - Handler is **not** touched here — it is server-global.
- No RAII / `defer` inside the library for handlers. **User is responsible** for calling destroy routines after `serve` returns.

---

## 5. Multi-Threading Semantics

- **Server model**: Fixed thread pool (`thread_count ≈ cores-1`), each with its own `nbio.Event_Loop`.
- **Handler sharing**: The **exact same** `Handler` struct (and entire `next` chain) is accessed concurrently by **every worker thread**.
  - `s.handler` is read from every `Server_Thread`.
  - Router maps and `Route` arrays are shared.
- **Thread safety contract**:
  - **Stateless** `Handle_Proc` → perfectly safe.
  - **Mutable user_data** → **must** be protected (see `rate_limit` example with `sync.Mutex`).
  - Odin has no automatic synchronization. Data races → undefined behavior (TSAN will catch in debug builds).
- `td` is `@(thread_local)` → you *can* attach per-thread state if needed, but the Handler API itself is global.

---

## 6. Allocator Usage

| Context                  | Allocator Used                          | Lifetime / Reset                     | Recommendation |
|--------------------------|-----------------------------------------|--------------------------------------|----------------|
| `Handler` creation       | Caller’s `context.allocator` (for rate_limit/router) | Server lifetime | Use server’s `conn_allocator` |
| Router patterns / maps   | `router.allocator`                      | Until `router_destroy`               | Same as above |
| Per-request temp data    | `virtual.Arena` (per `Connection`)      | Reset per request (implicit in clean loop) | `context.temp_allocator` inside handlers |
| `Connection` allocation  | `server.conn_allocator`                 | Server lifetime                      | Usually heap |
| User handler allocations | Current `context.allocator` / temp     | As per handler                       | Prefer temp for transients |

**Critical rule**: Never pass a thread-local allocator to `router_init` or `rate_limit`. The router lives on all threads.

---

## 7. Possible Problems & Gotchas

1. **Data races on shared state** (most common foot-gun).
2. **Dangling pointers** — allocating `Handler` on stack and taking `&h` → use after scope.
3. **Allocator mismatch** — router created with one allocator, destroyed with another → leak/corruption.
4. **Blocking handlers** — CPU-heavy work stalls the entire event loop thread (affects all connections on that core).
5. **Forgotten destroy** — memory leak of router maps / rate-limit maps on shutdown.
6. **Keep-alive reuse** — same connection re-calls handler repeatedly; per-connection state must be reset manually if stored in `req`/`res`.
7. **Closure lifetime** — the inner proc literal in `http.handler` is valid only as long as the returned `Handler` lives (which it does).
8. **OS/2 migration note** (recent commit) — allocator and thread behavior may have subtle changes; test shutdown paths.

---

## 8. Recommended Idioms (Production-Grade)

### 8.1 Stateless (Recommended Default)
```odin
my_handler := http.handler(proc(req: ^http.Request, res: ^http.Response) {
    http.respond_plain(res, "Hello")
})
```

### 8.2 Stateful with Middleware (Thread-Safe)
```odin
data := new(Rate_Limit_Data)  // or on stack if you manage lifetime
rate_limited := http.rate_limit(data, &next_handler, &opts, context.allocator)
defer rate_limit_destroy(data)
```

### 8.3 Full Router Pattern (Most Common)
```odin
router: http.Router
http.router_init(&router, context.allocator)  // or server.conn_allocator
defer http.router_destroy(&router)

http.route_get(&router, "/users/(%w+)", http.handler(my_user_handler))
http.route_post(&router, "/api/.*", http.handler(my_api_handler))

server_handler := http.router_handler(&router)
http.listen_and_serve(&server, server_handler, ...)
```

### 8.4 Per-Request Temp Data
```odin
http.handler(proc(req, res) {
    buf := make([]byte, 1024, context.temp_allocator)  // auto-freed at end of request
    // ...
})
```

### 8.5 Shutdown Sequence
```odin
http.serve(...)  // blocks
// after it returns:
router_destroy(&router)
rate_limit_destroy(...)
server_shutdown(&server)
```

### 8.6 Advanced: Fully Async Escape Hatch
Use `http.body(req, max, res, callback)` inside handler and return immediately — the thread is freed while body arrives.

---

**Summary (Architect View)**

`odin-http` follows the modern **Reactor + shared handler** pattern (like Nginx workers or Actix). The `Handler` is deliberately **stateless-by-default** and **value-based** to keep overhead near zero. The library correctly handles all I/O asynchronously via `core:nbio`, but **pushes thread-safety and cleanup responsibility onto the user**. This is the correct trade-off for maximum performance in a systems language like Odin.



## Cross‑callback capture

In Odin there are no capturing closures, so “cross‑callback capture” is always done explicitly via data passed to or stored alongside the callback. [reddit](https://www.reddit.com/r/ProgrammingLanguages/comments/1gplj9l/can_capturing_closures_only_exist_in_languages/)
In practice there are three main techniques:

1. **User data pointer + callback proc (C‑style)**
   Define your own pair `{proc, user_data}` and pass it around:

   ```odin
   Callback :: struct {
       proc:    proc(ctx: ^Context, event: ^Event) -> void,
       user_data: rawptr,
   }

   call_callback :: proc(cb: Callback, ctx: ^Context, ev: ^Event) {
       cb.proc(ctx, ev); // user_data reached via ctx or global, see below
   }
   ```

   Libraries that already take `rawptr user_data` (SDL, etc.) are used the same way: build a small capture struct, take its address, and cast back in the callback. [github](https://github.com/odin-lang/Odin/discussions/3296)

2. **Explicit capture struct (“manual closure”)**
   The idiom you’ve probably seen:

   ```odin
   _Capture :: struct {
       x: type_of(x),
       y: type_of(y),
       mem: type_of(mem),
       data: type_of(data),
       color: type_of(color),
       hash: type_of(hash),
   }

   cap: _Capture = { x = x, y = y, mem = mem, data = data, color = color, hash = hash };

   CallerFn(&cap, proc (user_data: rawptr) {
       using ref := cast(^_Capture) user_data;
       // now use x, y, mem, data, color, hash
   });
   ```

   This is the current “canonical” capture pattern in Odin when you have a `void* user_data` style callback. [github](https://github.com/odin-lang/Odin/discussions/3296)
   There has been discussion about nicer sugar (e.g. `#capture{a, b, c}`) but that’s not in the language yet. [github](https://github.com/odin-lang/Odin/discussions/3296)

3. **Using `context` (`context.user_pointer` / `context.user_index`)**
   For callbacks that **cannot** accept user data (third‑party APIs with a naked function pointer), you can pass per‑callback state through Odin’s `context` system. [gingerbill](https://www.gingerbill.org/article/2025/12/15/odins-most-misunderstood-feature-context/)

   Typical pattern:

   ```odin
   My_Context :: struct {
       user:   rawptr,
       index:  i32,
   }

   do_with_callback :: proc(cb: proc() -> void, data: ^My_Context) {
       ctx := context;
       ctx.user_pointer = data;
       ctx.user_index   = 0; // or whatever
       cb() or_return; // cb can read context.user_pointer
   }

   callback :: proc() {
       using ctx := context;
       state := cast(^My_Context) ctx.user_pointer;
       // use state.index, state.user, ...
   }
   ```

   This is especially useful when you need to adapt to bad C APIs that don’t give you a userdata parameter but call you synchronously. [reddit](https://www.reddit.com/r/programming/comments/1po2i0o/odins_most_misunderstood_feature_context/)

***

**Putting it together for “cross‑callback” flows**

When one callback needs access to variables defined in another scope, you generally:

- Put the shared state into a struct (`State`),
- Store a pointer to that struct either:
  - in the user_data field passed to all callbacks, or
  - in `context.user_pointer` (for APIs without userdata), [forum.odin-lang](https://forum.odin-lang.org/t/what-general-choices-do-i-have-for-passing-variables/1102)
- Have each callback `cast(^State)` and optionally `using` it.

Example with multiple callbacks sharing the same captured variables:

```odin
State :: struct {
    x, y: i32,
    color: Color,
    allocator: Allocator,
}

state := State{x, y, color, allocator};

register_callbacks(
    proc (ud: rawptr) {
        using s := cast(^State) ud;
        draw_point(s.x, s.y, s.color);
    },
    proc (ud: rawptr) {
        using s := cast(^State) ud;
        do_allocations(s.allocator);
    },
    &state,
);
```

That’s the idiomatic “cross‑callback capture” technique in Odin today.
