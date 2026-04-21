# Design: Post_Clients (Base Client)

**Version:** 0.1
**Authors:** g41797, Gemini CLI

---

## 1. Data Structures

The system uses a two-tier structure: `Post_Client_Unit` for individual request state and `Post_Clients` as the batch orchestrator.

### 1.1 Post_Client_Unit (Internal)
Stores the state for a single HTTP request lifecycle.

```odin
Post_Client_Unit :: struct {
    // Input Configuration
    url:         string,
    body:        []u8,           // Referenced, not owned
    mime:        http.Mime_Type,

    // odin-http primitives
    req:         client.Request,
    res:         client.Response,
    
    // Results
    client_err:  Maybe(client.Error),
    resp_body:   [dynamic]u8,    // Captured result body
    success:     bool,           // True if status == 200 and body readable
    
    // Threading
    thread:      ^thread.Thread,
}
```

### 1.2 Post_Clients (Public)
The orchestrator managing the collection of units.

```odin
Post_Clients :: struct {
    alloc:       mem.Allocator,
    units:       []Post_Client_Unit,
}
```

---

## 2. Execution Model: The "Thin Thread"

To minimize complexity and race conditions, the background thread is stripped of all logic except the blocking network I/O.

### 2.1 Main Thread: Preparation
Before spawning threads, `post_clients_run` performs the following on the **Main Thread** for each unit:
1. `client.request_init(&unit.req, .Post, clients.alloc)`
2. Header setup (`Content-Type` based on `unit.mime`).
3. Body setup (writing `unit.body` to `unit.req.body`).

### 2.2 Background Thread: I/O
The thread procedure is a minimal wrapper around the blocking `client.request` call:
```odin
post_client_io_proc :: proc(t: ^thread.Thread) {
    unit := (^Post_Client_Unit)(t.data)
    unit.res, unit.client_err = client.request(&unit.req, unit.url)
}
```

### 2.3 Main Thread: Analysis & Cleanup
After all threads are joined, the **Main Thread** performs:
1. `client.response_body(&unit.res)` to extract data.
2. Result capture into `unit.resp_body`.
3. `client.response_destroy(&unit.res)`.
4. `client.request_destroy(&unit.req)`.

---

## 3. Public API

### 3.1 Lifecycle
```odin
// Allocate the orchestrator and internal units.
post_clients_init :: proc(clients: ^Post_Clients, count: int, alloc: mem.Allocator) -> bool

// Join any pending threads and free all resources (requests, responses, buffers).
post_clients_destroy :: proc(clients: ^Post_Clients)
```

### 3.2 Task Configuration
```odin
// Configure a specific unit in the batch.
// url and body are referenced; they must remain valid until post_clients_run completes.
post_clients_set_task :: proc(clients: ^Post_Clients, index: int, url: string, body: []u8, mime := http.Mime_Type.Plain)
```

### 3.3 Execution
```odin
// Spawns N threads, waits for all to finish, and performs post-processing.
// Blocks until the entire batch is complete.
post_clients_run :: proc(clients: ^Post_Clients)
```

### 3.4 Results
```odin
// Check if a specific task was successful.
post_clients_was_successful :: proc(clients: ^Post_Clients, index: int) -> bool

// Access the results for a specific unit.
post_clients_get_result :: proc(clients: ^Post_Clients, index: int) -> (status: http.Status, body: []u8, err: Maybe(client.Error))
```

---

## 4. Design Rationale

### 4.1 Synchronous Run
Since `post_clients_run` is synchronous (it blocks until the batch is done), simply looping through `thread.join` is sufficient. This avoids passing complex synchronization primitives into the "thin" thread, keeping its scope as narrow as possible.

### 4.2 Handling "Empty" POST
If `unit.body` is nil or zero-length, `post_clients_run` will still initialize the `client.Request` but skip writing to the body buffer. `odin-http` handles zero-length POSTs correctly.

### 4.3 Error Aggregation
By storing `client.Error` in the unit, we allow tests to distinguish between network-level failures and application-level (HTTP status) failures.
