# impl_status.md — Implementation Log

Append one entry per stage. Do not proceed to the next stage if current stage result is FAIL.

---

## Plan v0.1 — Base_Server Refactor (complete)

### Stage 1: http_cs/base_server.odin
- **Result:** PASS
- **Details:** Core `Base_Server` struct and `base_*` procedures implemented.

### Stage 2: examples/echo.odin
- **Result:** PASS
- **Details:** `EchoApp` refactored to embed `Base_Server`. Redundant thread and context logic removed.

### Stage 3: examples/async/body_async.odin
- **Result:** PASS
- **Details:** Refactoring applied. Fixed `misuse_test.odin` (double-resume MPSC corruption) and `disconnect_test.odin` (listen on wrong nbio thread, user_data type mismatch).

### Stage 4: examples/async/direct_async.odin
- **Result:** PASS
- **Details:** `DirectApp` refactored to embed `Base_Server`. `direct_async_test.odin` updated with `app.port.(int)` cast.

### Stage 5: examples/async/split_async.odin
- **Result:** PASS
- **Details:** `SplitApp` refactored to embed `Base_Server`. No router — `route_handler` set directly.

### Stage 6: Remove time.sleep ready-waits from tests
- **Result:** PASS
- **Details:** Removed all `time.sleep` ready-waits from `echo_test.odin`, `body_async_test.odin`, `direct_async_test.odin`. `echo_test.odin` switched to ephemeral ports with `cs.build_url`.

### Stage 7: Remaining test files to Base_Server
- **Result:** PASS
- **Details:** `misuse_test.odin`, `disconnect_test.odin`, `split_async_test.odin` converted to `Base_Server`. `shutdown_test.odin` and `stress_test.odin` were already converted.

### Stage 8: Replace timing sleeps with explicit sync signals
- **Result:** PASS
- **Details:** `shutdown_test.odin` and `disconnect_test.odin` use `sync.Wait_Group` signals instead of `time.sleep` for ready/resumed synchronization.

### Stage 9: test_forgotten_nil timeout update
- **Result:** PASS
- **Details:** Applied as part of Stage 7 — timeout 200ms → 1000ms, `thread_count = 1`.

### Stage 10: Replace "safety net" with "cleanup guard" in docs
- **Result:** PASS
- **Details:** All five occurrences in `async-handlers.md` replaced.

---

## Plan v0.2 — API Normalization + Semaphore-Based Wait

### Stage 1: http_cs/base_server.odin
- **Result:** PASS
- **Details:** Added `core:time`, switched to `sync.Sema` for `ready` and `done`. Procs renamed to `base_server_*` and `base_router_*`.

### Stage 2: examples/echo.odin
- **Result:** PASS
- **Details:** API calls updated. `base_server_wait` used with 5s timeout in `example_echo_stop`.

### Stage 3: examples/async/body_async.odin
- **Result:** PASS
- **Details:** API calls updated.

### Stage 4: examples/async/direct_async.odin
- **Result:** PASS
- **Details:** API calls updated.

### Stage 5: examples/async/split_async.odin
- **Result:** PASS
- **Details:** API calls updated. Uses `base_server_destroy` for blocking wait.

### Stage 6: tests/functional/async/misuse_test.odin
- **Result:** PASS
- **Details:** API calls updated. Watcher thread removed from `test_forgotten_nil_safety_net`, replaced with `base_server_wait`.

### Stage 7: tests/functional/async/stress_test.odin
- **Result:** PASS
- **Details:** API calls updated.

### Stage 8: tests/functional/async/disconnect_test.odin
- **Result:** PASS
- **Details:** API calls updated.

### Stage 9: tests/functional/async/shutdown_test.odin
- **Result:** PASS
- **Details:** API calls updated.

### Stage 10: tests/functional/async/split_async_test.odin
- **Result:** PASS
- **Details:** API calls updated.

### Stage 11: Build verification (debug)
- **Result:** PASS
- **Details:** `bash kitchen/build_and_test_debug.sh` passed.

### Stage 12: kitchen/docs/addendums/base_server.md
- **Result:** PASS
- **Details:** Documentation updated to v0.4 with normalized API names and semaphore design.

### Stage 13: impl_status.md updates
- **Result:** PASS
- **Details:** This log updated.

### Stage 14: Final build verification
- **Result:** PASS
- **Details:** `bash kitchen/build_and_test.sh` passed all optimization levels.

---

## Summary of Changes (Plan v0.2)

- **Base_Server Core:** Switched from `sync.Wait_Group` to `sync.Sema` for `ready` and `done` signals. Normalized API names to `base_server_*` and `base_router_*`.
- **New API:** Replaced `base_thread_join` with `base_server_wait(s, timeout) -> bool` for safe, timed join.
- **Refactoring:** Updated `examples/echo.odin`, all `examples/async/*.odin`, and all `tests/functional/async/*.odin` to use the new API.
- **Test Optimization:** Removed the watcher-thread hack from `misuse_test.odin` in favor of `base_server_wait`.
- **Documentation:** Updated `base_server.md` (v0.4) to reflect the new API and design.
- **Verification:** All 14 stages passed, including a full CI run across all optimization levels (`bash kitchen/build_and_test.sh`).
