# Design: handler_with_body

**Authors:** g41797, Claude (claude-sonnet-4-6)

---

## 1. Motivation

The odin-http author identified this gap directly in the source:

```odin
// handlers.odin, line 17:
// TODO: something like http.handler_with_body which gets the body before calling the handler.
```

The current API forces every handler that needs the request body to implement the async `http.body()` callback pattern manually — boilerplate repeated across every non-trivial handler.

**Target use case:** Final handlers in not-so-simple flows — handlers that need both a request body AND their own context (pipeline state, config, shared resources) via `user_data`. Not middleware. Not stateless `Handle_Proc` cases.

This design is scoped as a potential future PR to odin-http.

---

## 2. Scope

- **In scope:** Final handlers that need the body pre-read before their logic runs.
- **Out of scope:** Middleware chaining. The wrapper does not use, check, or modify `handler.next`. This wrapper is designed for final handlers — `next` is ignored.
- **Not a replacement** for `http.handler()` — users who don't need the body continue using the existing API unchanged.

---

## 3. API Design

### New callback type

```odin
Body_Handler_Callback :: proc(
    handler: ^Handler,
    req:     ^Request,
    res:     ^Response,
    body:    Body,
    err:     Body_Error,
)
```

**Why `Callback` in the name:** This proc is called asynchronously after body is read — not synchronously like `Handler_Proc`. The name is honest about the execution model.

**Why no stateless `Body_Handle_Callback` variant:** A handler that needs the body almost always needs context (`user_data`). A stateless body handler is a degenerate case not worth a separate type.

**Why `body: Body` by value:** `Body :: string` is a fat pointer (ptr + len). Cheap to copy. The underlying memory is owned by odin-http's connection buffer — not the user.

**Body lifetime and ownership:**
- Body is **borrowed** from the connection buffer.
- Valid only for the duration of the callback.
- If the body is needed beyond the callback (e.g. to copy into a pipeline Message), the user must copy it themselves — as `bridge.odin` already does:
  ```odin
  msg.payload = make([]byte, len(body), alloc)
  copy(msg.payload, body)
  ```
- The user must **not** free the body.

**Error handling:**
- Both success and failure arrive via the same callback.
- When `err != nil`, `body` is an empty string.
- The user checks `err` first and responds accordingly — same convention as the existing `Body_Callback` in odin-http.
- No separate error handler proc — simpler API, user has full control over the error response.

### Internal data struct

```odin
Body_Handler_Data :: struct {
    cb:         Body_Handler_Callback,
    user_data:  rawptr,
    max_length: int,
}
```

### Wrapper function

```odin
handler_with_body :: proc(
    data:       ^Body_Handler_Data,
    cb:         Body_Handler_Callback,
    user_data:  rawptr,
    max_length: int,
) -> Handler
```

**Behaviour:**
- Fills `data^` with `{cb, user_data, max_length}` — does **not** allocate.
- Creates and returns an `http.Handler` with `h.user_data = data`.
- Its own `handle` proc calls `http.body(req, data.max_length, ...)` and returns immediately.
- When the body is ready (or failed), calls `cb(h, req, res, body, err)`.
- `handler.next` is not touched.
- `max_length`: `-1` = unlimited, following existing `http.body()` convention.

**Allocation and lifetime — follows `rate_limit` pattern (`vendor/odin-http/handlers.odin`):**
- `rate_limit` takes `data: ^Rate_Limit_Data` — the caller allocates, fills via the call, frees when done via `rate_limit_destroy`.
- `handler_with_body` follows the same contract: the caller owns `Body_Handler_Data`, passes a pointer, and is responsible for its lifetime.
- `data` must outlive the handler registration (i.e. the server lifetime).
- No allocator inside `handler_with_body` — allocation is always visible at the call site.

---

## 4. Usage (Calling Sequence)

This is what the user writes — in order — to use `handler_with_body`. The user never calls `http.body()` directly.

### Step 1 — Define your context struct

Put everything the handler needs into a struct. This is what goes into `user_data`.

```odin
My_Context :: struct {
    config: ^My_Config,
    // ... whatever the handler needs
}
```

### Step 2 — Write the Body_Handler_Callback

```odin
my_callback :: proc(
    handler: ^http.Handler,
    req:     ^http.Request,
    res:     ^http.Response,
    body:    http.Body,
    err:     http.Body_Error,
) {
    ctx := (^My_Context)(handler.user_data)

    if err != nil {
        http.respond(res, http.body_error_status(err))
        return
    }

    // body is valid here — copy if needed beyond this callback scope
    // use ctx.config, etc.
    http.respond_plain(res, "ok")
}
```

- Cast `handler.user_data` to get your context.
- Check `err` first — if non-nil, respond with an error status and return.
- `body` is borrowed — copy it if you need it beyond the callback (e.g. into a pipeline Message).

### Step 3 — Allocate Body_Handler_Data and construct the handler

The caller owns `Body_Handler_Data` — same pattern as `Rate_Limit_Data` with `rate_limit`.

```odin
ctx := My_Context{config = &my_config}

// Stack-allocated: lives as long as the enclosing scope (e.g. the server setup proc).
data: Body_Handler_Data
h := handler_with_body(&data, my_callback, &ctx, -1)
```

Or heap-allocated if lifetime needs to extend beyond the current scope:

```odin
data := new(Body_Handler_Data, my_allocator)
h := handler_with_body(data, my_callback, &ctx, -1)
// ... server runs ...
// After server stop:
free(data, my_allocator)
```

### Step 4 — Register with the router

```odin
http.route_post(&router, "/my/path", h)
```

### Step 5 — Cleanup

`Body_Handler_Data` has no dynamic fields — no destroy proc needed. If heap-allocated, `free(data, allocator)` after server stop. If stack-allocated, it is freed automatically when the scope exits.

---

## 5. Package

- New separate package in the template (not inside `vendor/`).
- No matryoshka dependency — imports only odin-http and core libs.
- Independently testable without pipeline or bridge.
- Suitable as a future standalone PR to odin-http.
- Package name and directory: TBD by g41797.

---

## 6. Test Server Requirements

### Why a separate test server is needed

Testing `handler_with_body` requires a real HTTP server — odin-http is async/event-driven and mocking is not viable. The existing `example_echo_start/stop` pattern from `examples/echo.odin` is the right model, but it is coupled to the matryoshka pipeline and not reusable for non-pipeline tests.

A new test server belongs in the `http_cs` package (already matryoshka-free), as a companion to the existing `Post_Client`.

### Requirements

1. **Accepts an `http.Handler` directly** — no pipeline wiring, no bridge. The test injects the handler under test at construction time.

2. **Ephemeral port support** — must support listening on port `0` (OS assigns a free port). Actual port must be retrievable after start via `get_listening_port` from `http_cs/helpers.odin`.

3. **Non-blocking start** — server starts on its own thread. The caller thread continues immediately after start returns.

4. **Ready signal** — start must block until the socket is bound and accepting. No race condition between start and first request. Model: `sync.Wait_Group` pattern from `Echo_Serve_Ctx` in `examples/echo.odin`.

5. **Graceful stop** — caller can shut the server down. All threads join cleanly. No leaked sockets or threads.

6. **Single route** — one POST route at a configurable path. No router complexity needed.

7. **No matryoshka dependency** — imports only odin-http and core libs.

8. **Lifecycle API** — `new_Test_Server` / `free_Test_Server` or equivalent start/stop pair, consistent with `Post_Client` conventions in `http_cs`.

### Test flow (informational)

```
1. Allocate Body_Handler_Data (stack or heap)
   Construct handler_with_body(&data, test_callback, &test_ctx, -1)
2. Start Test_Server with that handler on port 0
3. Get actual port via get_listening_port
4. Use Post_Client to POST a body to localhost:actual_port/path
5. Assert: test_callback received correct body + nil err
6. Assert: response body matches expected
7. Stop Test_Server
```

Client side reuses `http_cs.Post_Client` as-is — no new client code needed.

---

## 7. Files Referenced

| File | Relevance |
|---|---|
| `vendor/odin-http/handlers.odin` | `Handler`, `Handler_Proc`, `Handle_Proc`, `handler()`, TODO comment |
| `vendor/odin-http/body.odin` | `body()`, `Body`, `Body_Callback`, `Body_Error`, `body_error_status()` |
| `http_cs/post_client.odin` | `Post_Client` — reused for test client side |
| `http_cs/helpers.odin` | `get_listening_port()`, `build_url()` — reused |
| `examples/echo.odin` | `Echo_Serve_Ctx` pattern — model for Test_Server, not reused directly |
| `handlers/handler.odin` | `make_handler()` — shows `Handler_Proc` + `user_data` pattern |
| `handlers/bridge.odin` | `bridge_handle()` — shows `body()` callback pattern in practice |
