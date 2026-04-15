# Design: Base_Server

**Authors:** g41797, Claude (claude-sonnet-4-6)

---

## 1. Motivation

Every test of `handler_with_body` (and future HTTP-layer tests) requires a real HTTP server. odin-http is async/event-driven — mocking is not viable. The existing `examples/echo.odin` provides the right lifecycle pattern (`Echo_Serve_Ctx` + thread + ready signal) but is tightly coupled to the matryoshka pipeline and cannot be reused for non-pipeline tests.

Writing the full server lifecycle (thread, listen, ready signal, shutdown, cleanup) from scratch for every test is error-prone boilerplate. `Base_Server` extracts the common skeleton once, leaving all variation points open to the user.

---

## 2. Scope

- **In scope:** A reusable HTTP server foundation for tests and examples. No matryoshka dependency — imports only odin-http and core libs.
- **Out of scope:** Production server hardening (TLS, connection limits, signal handling). Users who need production features extend or replace the relevant stages.
- **Minimalistic foundation:** `Base_Server` is white-box template code — not an opaque framework. Users read it, copy it, and modify it. It does enforce a lifecycle sequence, but that sequence is fully visible and editable.

---

## 3. Design Reasoning: The "Script" Style

### 3.1 Why not a callback-based approach

A fixed set of callbacks (hook points) requires knowing all variation points in advance. But users may insert entirely new stages — adding cookie handling, rate limiting, custom middleware, or pre-listen configuration that the base design never anticipated. A fixed callback table cannot accommodate unknown future stages.

### 3.2 Why not the GOF Template pattern

Odin has no methods and no inheritance. A `proc` does not belong to a `struct`. The GOF Template pattern relies on virtual dispatch — subclasses override specific steps. Odin has neither virtual dispatch nor subclasses.

### 3.3 The "script" approach

Instead, the serve flow is written as a **linear sequence of proc calls** — a script — where every call takes `^Base_Server` (or `^My_Server` via `using`) as its first argument:

```odin
my_test :: proc() {
    s: My_Server
    base_server_init(&s, context.allocator)
    base_router_init(&s)

    user_add_routes(&s)                    // user stage

    base_route_handler(&s)
    base_thread_start(&s)                  // listen + serve thread; blocks until listen done

    // server is ready — port is known
    pc := cs.new_Post_Client(s.alloc)
    defer cs.free_Post_Client(pc)
    user_build_request(pc, &s)            // user stage
    cs.post_req_resp(pc)
    user_assert_response(pc, &s)          // user stage

    base_shutdown(&s)
    base_cleanup(&s)
}
```

**Properties of this style:**
- Every line is a proc call. There are no hidden hooks.
- User stages are ordinary procs — same signature convention as base procs.
- New stages are inserted by adding lines. Existing stages are replaced by removing or wrapping the base call.
- Client calls (`Post_Client` family) are first-class participants — the script interleaves server and client calls freely.
- Error handling is explicit at each stage — check `ok` from `base_thread_start`, inspect `s.listen_err` and `s.serve_err` after server exit.

### 3.4 Odin procs are not methods

`base_router_init(&s)` is not `s.router_init()`. Procs and structs are independent. This is intentional — users write their own procs with `^Base_Server` (or `^My_Server`) as the first argument, and they compose naturally with base procs in the same script.

### 3.5 User data: rawptr vs using

Two patterns for per-user state:

**Option A — `rawptr` field:**
```odin
Base_Server :: struct {
    // ...
    user_data: rawptr,
}
// User casts in their procs:
my_data := (^My_Data)(s.user_data)
```

**Option B — `using` (preferred):**
```odin
My_Server :: struct {
    using base: Base_Server,
    my_field:   My_Data,
}
// User accesses directly — no cast needed:
my_test_server :: proc(s: ^My_Server) {
    base_router_init(s)   // compatible: ^My_Server used as ^Base_Server via using
    s.my_field = ...
}
```

`using` is preferred: no casting, fields are accessible alongside base fields, type system assists.

---

## 4. Base_Server Struct (Preliminary)

```odin
Base_Server :: struct {
    // Allocator — passed at construction, used by all participants.
    // Must be valid for the entire server lifetime.
    alloc:         mem.Allocator,

    // odin-http core
    server:        http.Server,
    router:        Maybe(http.Router),
    route_handler: Maybe(http.Handler),

    // Server thread lifecycle
    server_thread: Maybe(^thread.Thread),
    ready:         sync.Wait_Group,        // signalled after listen completes

    // Results set by server thread, read by main thread after ready
    port:          Maybe(int),
    listen_err:    Maybe(net.Network_Error),
    serve_err:     Maybe(net.Network_Error),

    // Configuration — set before base_thread_start
    endpoint:      net.Endpoint,           // address + port (0 = ephemeral)
    opts:          http.Server_Opts,
}
```

**Notes:**
- `Maybe(T)` fields indicate "not yet initialized" — cleanup procs check presence before acting.
- `alloc` is set once at `base_server_init` and never changed.
- `endpoint` defaults to `{address = net.IP4_Loopback, port = 0}` (ephemeral, loopback).

---

## 5. Base Proc Signatures

All base procs take `^Base_Server` as first argument. User procs take `^My_Server` (which embeds `Base_Server` via `using`) — compatible with `^Base_Server` and directly usable alongside base procs in the same script.

### 5.1 Initialization

```odin
// Initialize Base_Server with allocator and default endpoint (loopback, ephemeral port).
// Must be called first. Sets alloc, endpoint, opts.
// Errors: none.
base_server_init :: proc(s: ^Base_Server, alloc: mem.Allocator)
```

```odin
// Initialize the router on s.alloc.
// Sets s.router.
// Errors: none (router_init does not fail).
base_router_init :: proc(s: ^Base_Server)
```

### 5.2 Route registration (user territory)

Base provides one convenience proc for the common single-POST-route case:

```odin
// Register a single POST route at the given path with the given handler.
// Requires: base_router_init called.
// Errors: none (route_post does not fail).
base_route_post :: proc(s: ^Base_Server, path: string, handler: http.Handler)
```

Users add more routes by calling `http.route_get`, `http.route_post`, etc. directly on `&s.router.(http.Router)` — or via their own wrapper procs.

### 5.3 Handler wiring

```odin
// Build the top-level handler from the router and store in s.route_handler.
// Requires: base_router_init called, at least one route registered.
// Errors: none.
base_route_handler :: proc(s: ^Base_Server)
```

### 5.4 Server thread

```odin
// Start the server thread. The thread runs http.listen then http.serve.
// Blocks the calling thread until http.listen completes (ready signal).
// After return: s.port is set (if listen succeeded), s.listen_err is set on failure.
// Errors: thread creation failure → returns false. listen error → s.listen_err set.
base_thread_start :: proc(s: ^Base_Server) -> (ok: bool)
```

**Server thread internals (not called directly):**
```odin
// Internal — runs on the server thread.
// 1. http.listen → sets s.port or s.listen_err
// 2. signals s.ready (main thread unblocks)
// 3. http.serve → sets s.serve_err on exit
@(private)
base_server_thread :: proc(t: ^thread.Thread)
```

### 5.5 Shutdown

```odin
// Signal the server to stop accepting connections and exit the serve loop.
// Calls http.server_shutdown. Does not join the thread — call base_cleanup after.
// Safe to call if server never started.
// Errors: none.
base_shutdown :: proc(s: ^Base_Server)
```

### 5.6 Cleanup (all called from main/test thread)

```odin
// Join and destroy the server thread. Waits for serve loop to exit.
// Safe to call if thread was never started (checks Maybe).
// Call after base_shutdown.
// Errors: none.
base_thread_join :: proc(s: ^Base_Server)
```

```odin
// Destroy the router and free its allocations.
// Safe to call if router was never initialized (checks Maybe).
// Errors: none.
base_router_destroy :: proc(s: ^Base_Server)
```

```odin
// Full cleanup: base_thread_join + base_router_destroy + zero the struct.
// Checks each Maybe field before acting — safe to call on partially-initialized server.
// Must be called AFTER base_shutdown (thread must be signalled before joining).
// Convenience wrapper for the common case.
// Errors: none.
base_cleanup :: proc(s: ^Base_Server)
```

---

## 6. User Proc Signatures (Examples)

These are fictional examples showing the convention — not base procs.

```odin
// User adds application-specific routes (cookies, auth, etc.)
user_add_routes :: proc(s: ^My_Server) {
    http.route_get(&s.router.(http.Router), "/cookies", http.handler(my_cookie_handler))
    base_route_post(s, "/echo", my_echo_handler)
}
```

```odin
// User builds the Post_Client request using the port discovered after base_thread_start.
user_build_request :: proc(pc: ^cs.Post_Client, s: ^My_Server) {
    pc.host_or_ip = "127.0.0.1"
    pc.port       = s.port.(int)
    pc.path       = "/echo"
    append(&pc.req_body, ..transmute([]u8)(string("hello")))
}
```

```odin
// User asserts the response.
user_assert_response :: proc(t: ^testing.T, pc: ^cs.Post_Client) {
    testing.expect(t, pc.status == true, "POST should succeed")
    testing.expect(t, pc.http_status == .OK, "HTTP status should be 200")
    testing.expect(t, string(pc.resp_body[:]) == "hello", "body should echo")
}
```

---

## 7. Complete Script Example

Minimal test using `Base_Server` directly (no `using`):

```odin
test_echo_base :: proc(t: ^testing.T) {
    s: Base_Server
    base_server_init(&s, context.allocator)

    base_router_init(&s)
    base_route_post(&s, "/echo", my_echo_handler)
    base_route_handler(&s)

    if !base_thread_start(&s) {
        // listen_err is set by the server thread before signalling ready
        testing.logf(t, "base_thread_start failed: %v", s.listen_err)
        testing.fail(t)
        base_cleanup(&s)
        return
    }
    // Shutdown then cleanup — order matters: signal first, join second.
    defer base_cleanup(&s)
    defer base_shutdown(&s)

    port, ok := s.port.(int)
    if !testing.expect(t, ok, "port should be set after successful listen") {
        return
    }

    pc := cs.new_Post_Client(s.alloc)
    defer cs.free_Post_Client(pc)
    pc.host_or_ip = "127.0.0.1"
    pc.port       = port
    pc.path       = "/echo"
    append(&pc.req_body, ..transmute([]u8)(string("hello")))

    cs.post_req_resp(pc)
    testing.expect(t, pc.status == true, "POST should succeed")
    // After test, defers fire: base_shutdown → base_cleanup (LIFO).
}
```

Extended test using `using` to add per-test state:

```odin
Echo_Test_Server :: struct {
    using base: Base_Server,
    received_body: string,   // captured by handler callback
}

test_echo_extended :: proc(t: ^testing.T) {
    s: Echo_Test_Server
    base_server_init(&s, context.allocator)

    base_router_init(&s)
    user_add_echo_route(&s)     // registers handler that captures into s.received_body
    base_route_handler(&s)

    if !base_thread_start(&s) {
        testing.logf(t, "base_thread_start failed: %v", s.listen_err)
        testing.fail(t)
        base_cleanup(&s)
        return
    }
    // Defers fire LIFO: base_shutdown first, then base_cleanup.
    defer base_cleanup(&s)
    defer base_shutdown(&s)

    pc := cs.new_Post_Client(s.alloc)
    defer cs.free_Post_Client(pc)
    user_build_request(pc, &s)
    cs.post_req_resp(pc)
    user_assert_response(t, pc, &s)
}
```

---

## 8. Files Referenced

| File | Relevance |
|---|---|
| `vendor/odin-http/examples/minimal/main.odin` | Minimal server skeleton — `http.Server` + `handler` + `listen_and_serve` |
| `vendor/odin-http/examples/complete/main.odin` | Full server — router, routes, middleware, rate limiting |
| `examples/echo.odin` | `Echo_Serve_Ctx` pattern — model for server thread + ready signal |
| `http_cs/post_client.odin` | Client side — `Post_Client`, `post_req_resp`, `run_on_thread` |
| `http_cs/helpers.odin` | `get_listening_port()`, `build_url()` |
| `kitchen/docs/addendums/handler_with_body.md` | Sister document — handler designed to work with Base_Server |
