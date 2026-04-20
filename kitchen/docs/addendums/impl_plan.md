# impl_plan.md — Async odin-http Handlers

**Version:** 0.8
**Design doc:** `kitchen/docs/addendums/async-handlers.md` (v1.0)
**Status tracking:** `kitchen/docs/addendums/impl_status.md` — updated after every stage
**Workflow:** Claude writes code and shows git commands. User runs git commands. Claude never runs git commands.
**Git remote:** currently disabled. Claude shows all commands including push. User decides which to run.
**Regression rule:** existing tests pass at end of every stage without exception.
**Old handler signatures:** unchanged throughout — R11 is a hard constraint.
**Stage verification:** after every stage — run debug build first; if green, run full build (all opt modes). Both must pass before the stage is recorded as PASS in `impl_status.md`.
**Git tagging:** after each stage commit in the submodule, run `git -C vendor/odin-http tag async-stageN`. Tags are the rollback anchor — do not skip.

---

## Repository Layout

```
matryoshka-http-template/          # parent repo, current working directory
├── vendor/
│   └── odin-http/                 # git submodule (fork: g41797/odin-http)
│       ├── server.odin            # MODIFY
│       ├── response.odin          # MODIFY
│       ├── resume.odin            # NEW
│       ├── internal/mpsc/         # already present — queue.odin, queue_test.odin, edge_test.odin
│       └── ... (other files — unchanged)
├── examples/
│   └── async/                     # NEW subfolder
│       ├── direct_async.odin
│       └── body_async.odin
├── tests/
│   ├── functional/
│   │   ├── echo_test.odin         # EXISTING — must pass every stage
│   │   └── async/                 # NEW subfolder
│   │       ├── direct_async_test.odin
│   │       ├── body_async_test.odin
│   │       ├── split_async_test.odin   # smoke test — gate for Stage 3
│   │       ├── shutdown_test.odin      # Stage 4
│   │       ├── disconnect_test.odin    # Stage 4
│   │       ├── stress_test.odin        # Stage 4
│   │       └── misuse_test.odin        # Stage 4 — negative tests
│   └── unit/
│       ├── handlers/bridge_test.odin   # EXISTING — must pass every stage
│       ├── http_cs/post_client_test.odin
│       └── pipeline/master_test.odin
└── kitchen/docs/addendums/
    ├── async-handlers.md          # design doc (v0.6, read-only during impl)
    ├── impl_plan.md               # this file
    └── impl_status.md             # stage-by-stage status log
```

---

## Stage 0 — Build Scripts + Baseline

**Goal:** Establish a clean baseline. Nothing can be called broken before Stage 0 passes.

### Parent repo (existing scripts — do not create)

`kitchen/build_and_test_debug.sh` — debug only (opt: none), fast.
`kitchen/build_and_test.sh` — all opt modes (none, minimal, size, speed, aggressive), full CI.

Both scripts use `BUILDS` and `TESTS` arrays. Run from the parent repo root.

Ask user to run for baseline check:
```
bash kitchen/build_and_test_debug.sh
bash kitchen/build_and_test.sh
```

### odin-http submodule (new scripts — Claude writes)

`vendor/odin-http/build_and_test_debug.sh` and `vendor/odin-http/build_and_test.sh` — same pattern as kitchen scripts, `BUILDS=(.)`, `TESTS=(internal/mpsc)`. Both added to `vendor/odin-http/.gitignore`.

**Ask user to run:**
```
git -C vendor/odin-http add .gitignore
git -C vendor/odin-http commit -m "stage0: ignore local build scripts"
git -C vendor/odin-http push
```

### odin-http CI update (Claude writes)

Update `vendor/odin-http/.github/workflows/ci.yml` — add opt matrix and test job for `internal/mpsc` with `ODIN_TEST_THREADS=1` on Windows.

**Ask user to run:**
```
git -C vendor/odin-http add .github/workflows/ci.yml
git -C vendor/odin-http commit -m "stage0: add opt matrix and test job to CI"
git -C vendor/odin-http push
```

**Ask user to run (parent repo):**
```
git add vendor/odin-http
git commit -m "stage0: update odin-http submodule pointer"
git push
```

**Exit criteria:** both parent scripts and both odin-http scripts exit 0. All existing tests green. Submodule changes and parent pointer committed.

**Status entry:** record result in `impl_status.md`.

---

## Stage 1 — Structural Changes Only (submodule)

**Goal:** Add new fields and imports. Zero logic changes. Existing behaviour preserved exactly.

**Files changed:** `vendor/odin-http/response.odin`, `vendor/odin-http/server.odin`

`response.odin` — add to import block:
```odin
import list "core:container/intrusive/list"
```

`response.odin` — `Response` struct, insert at the very beginning then append `async_state`:
```odin
Response :: struct {
    node:          list.Node,  // intrusive MPSC node — must be first field (mpsc.Queue constraint)
    async_handler: ^Handler,   // exact handler that called mark_async (middleware-safe resume)
    // ... existing fields unchanged ...
    async_state:   rawptr,     // nil = sync, non-nil = async pending
}
```

`response.odin` — add compile-time layout assertion immediately after the Response struct:
```odin
#assert(offset_of(Response, node) == 0, "Response.node must remain the first field — required by mpsc.Queue")
```

`server.odin` — add to import block:
```odin
import mpsc "internal/mpsc"
import "base:intrinsics"
```

`server.odin` — `Connection` struct, add after existing fields:
```odin
owning_thread: ^Server_Thread,  // set once in on_accept, never changes
```

`server.odin` — `Server_Thread` struct, add after existing fields:
```odin
resume_queue:  mpsc.Queue(Response),
async_pending: int,               // atomic; incremented by mark_async, decremented after resume handler
```

**No logic changes.** New fields are zero-valued at startup — safe.

**Ask user to run:**
```
git -C vendor/odin-http add response.odin server.odin
git -C vendor/odin-http commit -m "stage1: add async fields (node, async_handler, async_state, owning_thread, resume_queue, async_pending)"
git -C vendor/odin-http tag async-stage1
git -C vendor/odin-http push
```

**Ask user to run (parent repo):**
```
git add vendor/odin-http
git commit -m "stage1: update odin-http submodule pointer"
git push
```

**Exit criteria:** `bash kitchen/build_and_test_debug.sh` green → `bash kitchen/build_and_test.sh` green. All existing tests pass. Confirm examples build cleanly (no ABI regressions).

**Status entry:** record result in `impl_status.md`.

---

## Stage 2 — Wire Fields + Resume Loop (submodule)

**Goal:** Set `owning_thread` at accept time. Insert stall-aware, middleware-safe resume loop. Modify shutdown exit condition.

**Files changed:** `vendor/odin-http/server.odin`

`on_accept` proc — one line added:
```odin
c.owning_thread = td
```

`_server_thread_init` event loop — insert after `nbio.tick()`:
```odin
// Resume loop — stall-aware (bounded retry), non-blocking, io thread only.
// mpsc.pop returns nil in two cases: queue truly empty, or producer stall (< 10ns window).
// mpsc.length is NOT used for stall detection — it is incremented AFTER node linking,
// so it returns 0 during the stall window. A bounded retry resolves the stall correctly.
for {
    res := mpsc.pop(&td.resume_queue)
    if res == nil {
        // Bounded retry: distinguish stall from empty without relying on mpsc.length.
        stall := false
        for _ in 0..<3 {
            res = mpsc.pop(&td.resume_queue)
            if res != nil { stall = true; break }
        }
        if !stall { break }
    }
    context.temp_allocator = virtual.arena_allocator(&res._conn.temp_allocator)
    // Use the EXACT handler that originally called mark_async (middleware-safe).
    h := res.async_handler if res.async_handler != nil else res._conn.server.handler
    log.debugf("resume: dispatching handler, async_pending before decrement: %d",
        intrinsics.atomic_load(&td.async_pending))
    h.handle(h, &res._conn.loop.req, res)
    intrinsics.atomic_add(&td.async_pending, -1)
    // Safety net: handler must nil async_state before returning from resume branch.
    when ODIN_DEBUG {
        assert(res.async_state == nil,
            "async handler must set res.async_state = nil before returning from resume branch")
    } else {
        if res.async_state != nil {
            log.warn("async handler left async_state non-nil after resume — cleared")
            res.async_state = nil
        }
    }
    res.async_handler = nil  // clear for next request on this connection
}
```

Note on `res.connection` vs `res._conn`: the actual Response field is `_conn` (private).
The design doc uses `res.connection` as pseudocode. All Stage 2+ code uses `res._conn`.

Shutdown exit condition — replace existing `if s.closing` check:
```odin
if intrinsics.atomic_load(&s.closing) && intrinsics.atomic_load(&td.async_pending) == 0 {
    _server_thread_shutdown(s)
    break
}
```

**Ask user to run:**
```
git -C vendor/odin-http add server.odin
git -C vendor/odin-http commit -m "stage2: set owning_thread; add stall-safe resume loop; fix shutdown exit; add debug logs"
git -C vendor/odin-http tag async-stage2
git -C vendor/odin-http push
```

**Ask user to run (parent repo):**
```
git add vendor/odin-http
git commit -m "stage2: update odin-http submodule pointer"
git push
```

**Exit criteria:** `bash kitchen/build_and_test_debug.sh` green → `bash kitchen/build_and_test.sh` green. All existing tests pass. (Loop runs but queue is always empty — no effect on existing behaviour.)

**Status entry:** record result in `impl_status.md`.

---

## Stage 3 — New API + Guards (submodule)

**Goal:** Add the two public procs with v0.6 signatures. Add `on_response_sent` guard and disconnect guard. Existing sync path unchanged.

**Files changed/created:** `vendor/odin-http/resume.odin` (new), `vendor/odin-http/response.odin`

Create `vendor/odin-http/resume.odin` as a new file:
```odin
package http

import mpsc  "internal/mpsc"
import nbio  "core:nbio"
import "base:intrinsics"
import "core:log"

// mark_async marks the response as async and remembers the exact handler
// that is going async (critical for correct middleware resume).
// Call from inside Handler_Proc or Body_Callback — io thread only.
// Safe order: prepare work → mark_async → start background work.
// If background work fails to start, call cancel_async and return an error response.
mark_async :: proc(h: ^Handler, res: ^Response, state: rawptr) {
    if h != nil {
        res.async_handler = h
    } else if res.async_handler == nil {
        // No handler and no pre-set async_handler: in a middleware chain this causes
        // the double-execution bug that async_handler was introduced to fix.
        assert(false,
            "mark_async: h is nil and res.async_handler is not set — always pass h in a middleware chain")
        res.async_handler = res._conn.server.handler  // fallback for no-middleware case
    }
    res.async_state = state
    intrinsics.atomic_add(&res._conn.owning_thread.async_pending, 1)
    log.debugf("mark_async: async_pending now %d", intrinsics.atomic_load(&res._conn.owning_thread.async_pending))
}

// cancel_async rolls back the async intent set by mark_async.
// Call only when background work fails to start — io thread only.
// BOTH steps are mandatory on Part 1 failure:
//   1. http.cancel_async(res)             — rolls back state, decrements async_pending.
//   2. http.respond(res, .<error_status>)  — sends error to client.
// Omitting cancel_async: async_pending stays incremented — shutdown will hang.
// Omitting respond: request is silently dropped.
cancel_async :: proc(res: ^Response) {
    if res.async_state == nil {
        log.error("cancel_async called on response that is not in async state — ignored to prevent counter underflow")
        return
    }
    intrinsics.atomic_add(&res._conn.owning_thread.async_pending, -1)
    log.debugf("cancel_async: async_pending now %d", intrinsics.atomic_load(&res._conn.owning_thread.async_pending))
    res.async_state = nil
    res.async_handler = nil
}

// resume signals the owning io thread that async work is complete.
// Any thread may call. After this call do not touch res — io thread owns it.
resume :: proc(res: ^Response) {
    if res == nil { return }
    td := res._conn.owning_thread
    msg: Maybe(^Response) = res
    if mpsc.push(&td.resume_queue, &msg) {
        nbio.wake_up(td.event_loop)
    }
}
```

`response.odin` — add guard in `on_response_sent` (prevents arena reset while async cycle is pending):
```odin
on_response_sent :: proc(...) {
    if res.async_state != nil {
        return  // async cycle not finished; handler will call http.respond later
    }
    clean_request_loop(...)
}
```

`response.odin` — add disconnect guard at the top of `response_send`:
```odin
if conn.state >= .Closing || conn.state == .Will_Close {
    clean_request_loop(conn)
    return
}
```

**Stage 3 smoke test (mandatory gate — write before committing):**

Before the Stage 3 commit, create `tests/functional/async/split_async_test.odin` in the
parent repo. This is the Stage 3 correctness gate — it verifies the full async machinery
(resume loop, handler dispatch, async_pending accounting) using the split handler pattern
(§13c of design doc): `mark_async` + `resume` called synchronously on the io thread,
no background thread.

The test must assert:
1. Part 2 (resume call) runs exactly once
2. Response is received by the test client
3. `async_pending` returns to 0 after the cycle

Run this test in debug mode before accepting Stage 3 as PASS.

**Ask user to run:**
```
git -C vendor/odin-http add resume.odin response.odin
git -C vendor/odin-http commit -m "stage3: add hardened mark_async/cancel_async/resume API; add on_response_sent and disconnect guards"
git -C vendor/odin-http tag async-stage3
git -C vendor/odin-http push
```

**Ask user to run (parent repo):**
```
git add vendor/odin-http tests/functional/async/split_async_test.odin
git commit -m "stage3: update odin-http submodule pointer; add split handler smoke test"
git push
```

**Exit criteria:** `bash kitchen/build_and_test_debug.sh` green → `bash kitchen/build_and_test.sh` green. All existing tests pass. **Split handler smoke test passes** (mandatory gate).

**Status entry:** record result in `impl_status.md`.

---

## Stage 4 — Examples + Tests (parent repo)

**Goal:** Demonstrate and verify the new API end-to-end. Examples + full test suite including edge cases, negative tests, and stress.

**Files created:**
- `examples/async/direct_async.odin` — uses `http.mark_async(h, res, work)` (§13a of design doc)
- `examples/async/body_async.odin` — sets `res.async_handler = h` before `http.body` (§13b)
- `examples/async/split_async.odin` — `mark_async` + `resume` from io thread, no thread (§13c)
- `tests/functional/async/direct_async_test.odin` — starts example server, POSTs, asserts response
- `tests/functional/async/body_async_test.odin` — same for body path
- `tests/functional/async/split_async_test.odin` — already written in Stage 3; move here if kept in parent repo

**Pattern:** follows `tests/functional/echo_test.odin` — `example_*_start` / `example_*_stop`, ephemeral port, `http_cs.Post_Client`.

**Error handling coverage:** examples show Rule 1 (cancel_async + respond on Part 1 failure). Background processing failure (Rule 2) is not shown in skeletons — handling is the user's responsibility; see design doc §12 item 7.

**Additional tests (Stage 4 only):**

`tests/functional/async/shutdown_test.odin` — shutdown with pending async:
- Start server; send request; handler calls `mark_async`
- Call `server_shutdown` from a goroutine
- Background work finishes and calls `resume`
- Assert: server exits cleanly within timeout; response received by client

`tests/functional/async/disconnect_test.odin` — client disconnect during async:
- Start server; client sends request; handler calls `mark_async`
- Client closes TCP connection
- Background work finishes and calls `resume`
- Assert: server does not crash; cleanup runs (arena reset, no leak)

`tests/functional/async/stress_test.odin` — burst concurrency:
- Send 100 concurrent async requests; each goes async with random delay 1–50ms
- Assert: all 100 responses received with correct body
- Assert: server shuts down cleanly; `async_pending` reaches 0

`tests/functional/async/misuse_test.odin` — negative / misuse cases:
- Double `resume`: call `resume(res)` twice; assert second call handled safely
- Missing `cancel_async`: call `mark_async` then return error without `cancel_async`; verify `async_pending` is wrong (demonstrates the bug)
- Forgotten `async_state = nil`: return from Part 2 without clearing; assert safety net fires (log warning in release, assert in debug)

**CI multi-thread stress job (lower priority — add after core tests pass):**

In `vendor/odin-http/.github/workflows/ci.yml`, add a Linux job that runs the stress test
with `ODIN_TEST_THREADS=N` (N = available cores). This validates MPSC queue safety and
`async_pending` accounting under concurrent load — conditions not exercised by single-threaded
test runs. Defer this until the happy-path and misuse tests pass cleanly.

**Kitchen scripts updated** — in both `kitchen/build_and_test_debug.sh` and `kitchen/build_and_test.sh`, extend the `TESTS` array:
```bash
TESTS=(
    tests/unit/pipeline
    tests/unit/handlers
    tests/unit/http_cs
    tests/functional
    tests/functional/async
)
```

**Ask user to run:**
```
git add examples/async/ tests/functional/async/ kitchen/build_and_test_debug.sh kitchen/build_and_test.sh
git commit -m "stage4: async examples; full test suite (happy path, shutdown, disconnect, stress, misuse)"
git push
```

**Exit criteria:** `bash kitchen/build_and_test_debug.sh` green → `bash kitchen/build_and_test.sh` green. All existing tests pass. All new async tests pass including stress and negative tests.

**Status entry:** record result in `impl_status.md`.

---

## Stage 5 — Submodule Pointer Update + Polish

**Goal:** Final submodule pointer update and full regression run.

**Actions:**
1. Verify submodule HEAD is at Stage 3 commit.
2. Update parent repo submodule pointer.
3. Run both kitchen scripts one final time.

**Ask user to run:**
```
git add vendor/odin-http
git commit -m "stage5: update odin-http submodule to async-handlers v0.6 implementation"
git push
```

**Exit criteria:** `bash kitchen/build_and_test_debug.sh` green → `bash kitchen/build_and_test.sh` green. All tests pass. Submodule pointer committed.

**Status entry:** record result in `impl_status.md`.

---

## impl_status.md — Format

After each stage, append to `impl_status.md`:

```
## Stage N — <name>
Date: YYYY-MM-DD
Result: PASS / FAIL
Notes: <anything notable, blockers, deviations from plan>
Next: Stage N+1 / blocked on <reason>
```

If a stage fails, do not proceed to the next stage. Record the failure and stop.

---

## Key Constraints Summary

| Constraint | Rule |
|---|---|
| Old handler signatures | Unchanged. R11 is a hard requirement. |
| Existing tests | Must pass after every stage. |
| Middleware safety | Handled by `async_handler` field — v0.6 design. |
| Git remote | Currently disabled. No push/pull without user decision. |
| Git operations | Claude shows all commands (commit, push, etc.). User decides which to run. Claude never runs git. |
| Submodule changes | Committed inside `vendor/odin-http` separately. |
| Stage verification | Debug build first → if green → full build all modes. |
| Git tagging | `git -C vendor/odin-http tag async-stageN` after each submodule commit. Rollback anchor. |
| New examples | `examples/async/` subfolder. |
| New tests | `tests/functional/async/` subfolder. |
| Stage 3 gate | Split handler smoke test must pass before Stage 3 is recorded PASS. |
| mpsc.length | NOT used for stall detection — length = 0 during stall window. Use bounded retry (3 pops). |
| ODIN_DEBUG | Async state safety net: assert in debug, log.warn+clear in release. |
| cancel_async guard | Must guard against double-call (nil async_state check). |
| res._conn | Private field name in actual code. Design doc pseudocode uses `res.connection`. |
