# Requirements: Post_Clients (Base Client)

**Version:** 0.1
**Authors:** g41797, Gemini CLI

---

## 1. Purpose
Provide a reusable "Base Client" for functional testing that eliminates code duplication. It must provide a high-level "script-like" API for both single-request and multi-request (fan-out/stress) scenarios.

---

## 2. Functional Requirements

### 2.1 Protocol Support
- **Method:** Strictly `POST`.
- **Scheme:** `http://` (unencrypted).
- **Body:** Support for arbitrary byte slices, including zero-length (empty) bodies.
- **Content-Type:** 
    - Optional, defaulting to `text/plain`.
    - Support for `odin-http` Mime-Type enums.

### 2.2 Concurrency & Fan-Out
- **Batch Support:** Must support running $N$ concurrent clients against a single server.
- **Orchestration:** A single "manager" structure (`Post_Clients`) must handle the group lifecycle.
- **Transparency:** The user should not manually manage `sync.Wait_Group` or individual threads at the test level.

### 2.3 Execution Model
- **Thread Locality:**
    - **Main Thread:** Handles request preparation (`client.request_init`), URL building, body allocation, header setup, and final response analysis/destruction.
    - **Background Thread:** Performs *only* the blocking `client.request` network call (the "send/receive" operation).
- **Graceful Cleanup:** The system must automatically free all `odin-http` request/response resources upon destruction.

---

## 3. API Requirements

### 3.1 Lifecycle
- `init(count)`: Pre-allocate resources for $N$ clients.
- `destroy()`: Join all threads and free all memory (requests, responses, buffers).

### 3.2 Configuration
- `set_task(index, url, body, mime)`: Configure the payload for a specific client in the batch.

### 3.3 Execution
- `run()`: Execute all configured tasks concurrently and block until the entire batch is finished.

### 3.4 Inspection
- `get_result(index)`: Retrieve the resulting `http.Status`, response body, or error code for a specific task.

---

## 4. Error Handling
- **Non-blocking Errors:** Errors during preparation (e.g., URL building) should be captured in the result state.
- **Network Errors:** Capture raw `net.Network_Error` or `client.Error` into a machine-readable field (no `fmt.printf` only).
- **Validation:** Provide a simple `was_successful(index)` check.

---

## 5. Non-Functional Requirements
- **Dependency:** Must only depend on `odin-http`, `core`, and local `http_cs` helpers.
- **Performance:** Overhead of the orchestrator must be negligible compared to the network I/O.
- **Style:** Match the "script" pattern established by `Base_Server`.
