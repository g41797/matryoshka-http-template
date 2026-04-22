# Design: Base_Server

**Version:** 0.4
**Authors:** g41797, Claude (claude-sonnet-4-6)

---

## 1. Motivation

Every test of `handler_with_body` (and future HTTP-layer tests) requires a real HTTP server. odin-http is async/event-driven — mocking is not viable. The existing `examples/echo.odin` provides the right lifecycle pattern (`Echo_Serve_Ctx` + thread + ready signal) but is tightly coupled to the matryoshka pipeline and cannot be reused for non-pipeline tests.

Writing the full server lifecycle (thread, listen, ready signal, shutdown, cleanup) from scratch for every test is error-prone boilerplate. `Base_Server` extracts the common skeleton once, leaving every stage open to change.

---

## 2. Scope

- **In scope:** A reusable HTTP server foundation for tests and examples. No matryoshka dependency — imports only odin-http and core libs.
- **Out of scope:** Production server hardening (TLS, connection limits, signal handling). Users who need production features extend or replace the relevant stages.
- **Minimalistic foundation:** `Base_Server` is white-box template code — not a black box. Users read it, copy it, and modify it. It does enforce a lifecycle sequence, but that sequence is fully visible and editable.

**Rule: Long-lived objects are heap-allocated, never on the stack.**
A `Base_Server` (or `My_Server`) lives for the duration of a server thread. Stack allocation is wrong for that lifetime. Any struct that crosses thread boundaries or outlives the creating scope must be heap-allocated via an explicit allocator. Allocators are always visible at the call site — no `= context.allocator` defaults.

---

## 3. Design Reasoning: The "Script" Style

### 3.1 Why not a callback-based approach

A fixed set of callbacks (hook points) requires knowing all variation points in advance. But users may insert entirely new stages — adding cookie handling, rate limiting, custom middleware, or pre-listen configuration that the base design never anticipated. A fixed callback table cannot accommodate unknown future stages.

### 3.2 Why not the GOF Template pattern

Odin has no methods and no inheritance. A `proc` does not belong to a `struct`. The GOF Template pattern relies on virtual dispatch — subclasses override specific steps. Odin has neither virtual dispatch nor subclasses.

### 3.3 The "script" approach

Instead, the serve flow is written as a **linear sequence of proc calls** — a script — where every call takes `^Base_Server` (or `^My_Server` via `using`) as its first argument. The script is split into two procs:

- **`examples_echo`** (the run proc): allocates the server, executes the for-loop script, captures the result, then calls `done`.
- **`done`**: unconditional cleanup — always runs regardless of whether any stage failed. Shuts down the server, frees resources, and deallocates.

```odin
// straight code — no testing.T, no framework dependency
examples_echo :: proc(alloc: mem.Allocator) -> bool {
    s: Maybe(^My_Server)

    for {
        ptr := new(My_Server, alloc)
        if ptr == nil                   { break }
        s = ptr
        if !base_server_init(ptr, alloc){ break }
        if !base_router_init(ptr)       { break }
        if !user_add_routes(ptr)        { break }   // user stage
        if !base_router_handler(ptr)    { break }
        if !base_server_start(ptr)      { break }

        // server is up — client calls are also part of the script
        clients: cs.Post_Clients
        cs.post_clients_init(&clients, 1, alloc)
        defer cs.post_clients_destroy(&clients)

        user_build_request(&clients, 0, ptr)        // user stage
        cs.post_clients_run(&clients)

        break  // normal exit
    }

    server, ok := s.(^My_Server)
    if !ok { return false }
    base_server_shutdown(server)
    base_server_wait(server, 5 * time.Second)       // serve_err is now set
    err := server.error
    base_router_destroy(server)
    free(server, server.alloc)
    return err == .none
}
```

The test is one line — `testing.T` never enters the example or any `base*`/`user*` proc:

```odin
test_echo :: proc(t: ^testing.T) {
    testing.expect(t, examples_echo(context.allocator), "echo example failed")
}
```

**Properties of this style:**
- Every line is a proc call. There are no hidden hooks.
- User stages are ordinary procs — same signature convention as base procs.
- New stages are inserted by adding lines. Existing stages are replaced by removing or wrapping the base call.
- client calls are also part of the script.
- The `for {}` loop provides structured early exit without `goto`. A `break` anywhere exits to `done`.
- `done` is unconditional — cleanup always runs.
- The example is runnable standalone — no test framework required.

### 3.4 Odin procs are not methods

`base_router_init(&s)` is not `s.router_init()`. Procs and structs are independent. This is intentional — users write their own procs with `^Base_Server` (or `^My_Server`) as the first argument — user procs are called the same way, just another line in the script.

### 3.5 How users add functionality

Users extend `Base_Server` by embedding it with `using` and adding their own fields:

```odin
My_Server :: struct {
    using base:    Base_Server,
    received_body: string,
    user_err:      string,
}
```

Because `Base_Server` is at offset zero, `^My_Server` is compatible with `^Base_Server` — all base procs accept it directly. Users write their own procs with `^My_Server` as the first argument:

```odin
user_add_routes :: proc(s: ^My_Server) -> bool {
    base_router_post(s, "/echo", my_echo_handler)
    return true
}
```

User procs are called the same way — just another line in the script.

---

## 4. Error Handling

### 4.1 Error type

```odin
Base_Server_Error :: enum {
    none,
    thread_create_failed,
    listen_failed,
    serve_failed,
    user_error,   // set by user procs; specifics stored in My_Server user fields
}
```

`user_error` is a marker — the enum signals category (base error vs user error), details live in a user-chosen field in `My_Server`. No `any`, no `rawptr` error fields — type-safe, no allocations.

### Error Handling Details (v0.3)

The `Base_Server_Error` enum in the `Base_Server` struct indicates the *category* of failure (e.g., `.listen_failed`, `.serve_failed`). For more detailed information about the underlying network issue, the `listen_err` and `serve_err` fields (of type `Maybe(net.Network_Error)`) provide the specific network error. Always check the `error` enum first to determine *what* failed, and then inspect `listen_err` or `serve_err` if detailed diagnostics are required for the *why*. These detail fields are mutually exclusive: only one will be set at a time corresponding to the `error` category.

### 4.2 Every proc returns bool

All `base*` and `user*` procs return `(ok: bool)`. On failure the proc sets `s.error` to the appropriate enum value and returns `false`. The for-loop script checks each call:

```odin
if !base_server_start(s) { break }
```

Cleanup procs (`base_server_shutdown`, `base_server_destroy`) do **not** return bool — they are unconditional.

### 4.3 User error pattern

User procs set `s.error = .user_error` and store specifics in a field they add to `My_Server`:

```odin
My_Server :: struct {
    using base: Base_Server,
    user_err:   string,   // populated when error == .user_error
}

user_add_routes :: proc(s: ^My_Server) -> bool {
    // something failed
    s.error    = .user_error
    s.user_err = "route registration failed: path collision"
    return false
}
```

The `done` proc (or the test wrapper) inspects `s.error` after the script exits to check what failed.

---

## 5. Base_Server Struct

```odin
Base_Server :: struct {
    // Allocator — passed at construction, stored for use by cleanup (free).
    // Must be valid for the entire server lifetime.
    alloc:         mem.Allocator,

    // odin-http core
    server:        http.Server,
    router:        Maybe(http.Router),
    route_handler: Maybe(http.Handler),

    // Server thread lifecycle
    server_thread: Maybe(^thread.Thread),
    ready:         sync.Sema,              // signalled after listen completes
    done:          sync.Sema,              // signalled when server thread exits

    // Results set by server thread, read by main thread after ready
    port:          Maybe(int),
    listen_err:    Maybe(net.Network_Error),
    serve_err:     Maybe(net.Network_Error),

    // Configuration — set before base_server_start
    endpoint:      net.Endpoint,           // address + port (0 = ephemeral)
    opts:          http.Server_Opts,

    // Error state — set by any base or user proc on failure
    error:         Base_Server_Error,
}
```

**Notes:**
- `Maybe(T)` fields indicate "not yet initialized" — cleanup procs check presence before acting.
- `alloc` is set at `base_server_init` and used by `base_server_destroy` to free the struct itself.
- `endpoint` defaults to `{address = net.IP4_Loopback, port = 0}` (ephemeral, loopback).
- `s` is always a pointer (`^Base_Server` or `^My_Server`) — never a stack value.

---

## 6. Base Proc Signatures

All base procs take `^Base_Server` as first argument. User procs take `^My_Server` (which embeds `Base_Server` via `using`) — compatible with `^Base_Server` and directly usable alongside base procs in the same script.

All base procs return `(ok: bool)`. On failure: `s.error` is set, `false` is returned. Cleanup procs are unconditional and return nothing.

### 6.1 Initialization

```odin
// Initialize Base_Server fields with allocator and default endpoint (loopback, ephemeral port).
// Sets alloc, endpoint, opts. Stores alloc for use by base_server_destroy (free).
// s must be heap-allocated by the caller: new(Base_Server, alloc) or new(My_Server, alloc).
// Errors: none (always returns true). The boolean return value is maintained for consistency with other `base` procedures, allowing for uniform scripting patterns such as `if !base_server_init(s, alloc) { break }`.
base_server_init :: proc(s: ^Base_Server, alloc: mem.Allocator) -> (ok: bool)
```

```odin
// Initialize the router on s.alloc.
// Sets s.router.
// Errors: none (router_init does not fail).
base_router_init :: proc(s: ^Base_Server) -> (ok: bool)
```

### 6.2 Route registration (user territory)

Base provides one convenience proc for the common single-POST-route case:

```odin
// Register a single POST route at the given path with the given handler.
// Requires: base_router_init called.
// Errors: none (route_post does not fail).
base_router_post :: proc(s: ^Base_Server, path: string, handler: http.Handler) -> (ok: bool)
```

Users add more routes by calling `http.route_get`, `http.route_post`, etc. directly on `&s.router.(http.Router)` — or via their own wrapper procs.

### 6.3 Handler wiring

```odin
// Build the top-level handler from the router and store in s.route_handler.
// Requires: base_router_init called, at least one route registered.
// Errors: none.
base_router_handler :: proc(s: ^Base_Server) -> (ok: bool)
```

### 6.4 Server thread

```odin
// Start the server thread. The thread runs http.listen then http.serve.
// Blocks the calling thread until http.listen completes (ready signal).
// After return: s.port is set (if listen succeeded), s.listen_err is set on failure.
// On thread creation failure: sets s.error = .thread_create_failed, returns false.
// On listen failure: sets s.error = .listen_failed, s.listen_err set, returns false.
base_server_start :: proc(s: ^Base_Server) -> (ok: bool)
```

**Server thread internals (not called directly):**
```odin
// Internal — runs on the server thread.
// 1. defer sync.sema_post(&s.done)
// 2. http.listen → sets s.port or s.listen_err + s.error
// 3. signals s.ready (main thread unblocks)
// 4. http.serve → sets s.serve_err + s.error on exit
@(private)
base_server_thread :: proc(t: ^thread.Thread)
```

### 6.5 Shutdown

```odin
// Signal the server to stop accepting connections and exit the serve loop.
// Calls http.server_shutdown. Does not join the thread — base_server_wait/destroy does that.
// Safe to call if server never started (checks state before acting).
// Unconditional — no return value.
base_server_shutdown :: proc(s: ^Base_Server)
```

### 6.6 Cleanup

```odin
// Wait for server to finish. Returns false if timeout elapsed (server may still be running).
// Returns true if server finished within timeout; s.error reflects exit status.
// Safe to call if thread was never started (checks Maybe).
base_server_wait :: proc(s: ^Base_Server, timeout: time.Duration) -> (ok: bool)
```

```odin
// Destroy the router and free its allocations.
// Safe to call if router was never initialized (checks Maybe).
// Unconditional — no return value.
base_router_destroy :: proc(s: ^Base_Server)
```

```odin
// Full cleanup: blocking base_server_wait + base_router_destroy + free(s, s.alloc).
// Checks each Maybe field before acting — safe to call on partially-initialized server.
// Must be called AFTER base_server_shutdown (thread must be signalled before joining).
// Frees the Base_Server (or My_Server) struct itself via s.alloc.
// Unconditional — no return value.
base_server_destroy :: proc(s: ^Base_Server)
```

---

## 7. User Proc Signatures (Examples)

These are fictional examples showing the convention — not base procs. All user procs follow the same pattern: first arg `^My_Server`, return `bool`, set `s.error = .user_error` on failure.

```odin
// User adds application-specific routes.
user_add_routes :: proc(s: ^My_Server) -> bool {
    http.route_get(&s.router.(http.Router), "/cookies", http.handler(my_cookie_handler))
    base_router_post(s, "/echo", my_echo_handler)
    return true
}
```

```odin
// User builds the Post_Clients request using the port discovered after base_server_start.
user_build_request :: proc(clients: ^cs.Post_Clients, index: int, s: ^My_Server) {
    url := cs.build_url("127.0.0.1", s.port.(int), "/echo", context.temp_allocator)
    cs.post_clients_set_task(clients, index, url, transmute([]u8)string("hello"))
}
```

---

## 8. Complete Script Example

### 8.1 Minimal — Base_Server directly (no `using`)

```odin
examples_echo_base :: proc(alloc: mem.Allocator) -> bool {
    s: Maybe(^Base_Server)

    for {
        ptr := new(Base_Server, alloc)
        if ptr == nil                                           { break }
        s = ptr
        if !base_server_init(ptr, alloc)                        { break }
        if !base_router_init(ptr)                               { break }
        if !base_router_post(ptr, "/echo", my_echo_handler)     { break }
        if !base_router_handler(ptr)                            { break }
        if !base_server_start(ptr)                              { break }

        port := ptr.port.(int)

        clients: cs.Post_Clients
        cs.post_clients_init(&clients, 1, alloc)
        defer cs.post_clients_destroy(&clients)

        cs.post_clients_set_task(&clients, 0, cs.build_url("127.0.0.1", port, "/echo", context.temp_allocator), transmute([]u8)string("hello"))
        cs.post_clients_run(&clients)

        break
    }

    server, ok := s.(^Base_Server)
    if !ok { return false }
    base_server_shutdown(server)
    base_server_wait(server, 5 * time.Second)       // serve_err is now set
    err := server.error
    base_router_destroy(server)
    free(server, server.alloc)
    return err == .none
}

test_echo_base :: proc(t: ^testing.T) {
    testing.expect(t, examples_echo_base(context.allocator), "echo_base failed")
}
```

### 8.2 Extended — `using` to add per-test state

```odin
Echo_Test_Server :: struct {
    using base:    Base_Server,
    received_body: string,   // captured by handler callback
    user_err:      string,   // populated when error == .user_error
}

examples_echo_extended :: proc(alloc: mem.Allocator) -> bool {
    s: Maybe(^Echo_Test_Server)

    for {
        ptr := new(Echo_Test_Server, alloc)
        if ptr == nil                           { break }
        s = ptr
        if !base_server_init(ptr, alloc)        { break }
        if !base_router_init(ptr)               { break }
        if !user_add_echo_route(ptr)            { break }
        if !base_router_handler(ptr)            { break }
        if !base_server_start(ptr)              { break }

        clients: cs.Post_Clients
        cs.post_clients_init(&clients, 1, alloc)
        defer cs.post_clients_destroy(&clients)
        user_build_request(&clients, 0, ptr)
        cs.post_clients_run(&clients)

        break
    }

    server, ok := s.(^Echo_Test_Server)
    if !ok { return false }
    base_server_shutdown(server)
    base_server_wait(server, 5 * time.Second)       // serve_err is now set
    err := server.error
    base_router_destroy(server)
    free(server, server.alloc)
    return err == .none
}

test_echo_extended :: proc(t: ^testing.T) {
    testing.expect(t, examples_echo_extended(context.allocator), "echo_extended failed")
}
```

**Defers fire LIFO** — if the user uses `defer` for cleanup instead of calling `base_server_shutdown` / `base_server_destroy` explicitly, the order must be: `defer base_server_destroy(s)` first (registered first, fires last), `defer base_server_shutdown(s)` second (registered second, fires first). Shutdown must signal before destruction joins.

---

## 9. Files Referenced

| File | Relevance |
|---|---|
| `vendor/odin-http/examples/minimal/main.odin` | Minimal server skeleton — `http.Server` + `handler` + `listen_and_serve` |
| `vendor/odin-http/examples/complete/main.odin` | Full server — router, routes, middleware, rate limiting |
| `examples/echo.odin` | `EchoApp` pattern — model for server thread + ready signal |
| `http_cs/post_client.odin` | Client side — `Post_Client`, `post_req_resp`, `run_on_thread` |
| `http_cs/helpers.odin` | `get_listening_port()`, `build_url()` |
| `kitchen/docs/addendums/handler_with_body.md` | Sister document — handler designed to work with Base_Server |
