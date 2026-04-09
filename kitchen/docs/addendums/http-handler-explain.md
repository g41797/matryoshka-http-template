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
