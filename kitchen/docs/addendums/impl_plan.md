# impl_plan.md — Async odin-http Handlers

**Version:** 0.3
**Design doc:** `kitchen/docs/addendums/async-handlers.md` (v0.5)
**Status tracking:** `kitchen/docs/addendums/impl_status.md` — updated after every stage
**Workflow:** Claude writes code and shows git commands. User runs git commands. Claude never runs git commands.
**Git remote:** currently disabled. Claude shows all commands including push. User decides which to run.
**Regression rule:** existing tests pass at end of every stage without exception.
**Old handler signatures:** unchanged throughout — R11 is a hard constraint.
**Stage verification:** after every stage — run debug build first; if green, run full build (all opt modes). Both must pass before the stage is recorded as PASS in `impl_status.md`.

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
│   │       └── body_async_test.odin
│   └── unit/
│       ├── handlers/bridge_test.odin   # EXISTING — must pass every stage
│       ├── http_cs/post_client_test.odin
│       └── pipeline/master_test.odin
└── kitchen/docs/addendums/
    ├── async-handlers.md          # design doc (v0.5, read-only during impl)
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

The odin-http submodule has no local build scripts. Claude creates two, following the exact same pattern as the kitchen scripts, with `BUILDS` and `TESTS` arrays reflecting the submodule's packages:

`vendor/odin-http/build_and_test_debug.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
BUILDS=(.)                # root odin-http package (package http)
TESTS=(internal/mpsc)
# ... same loop structure as kitchen/build_and_test_debug.sh
```

`vendor/odin-http/build_and_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
OPTS=(none minimal size speed aggressive)
BUILDS=(.)                # root odin-http package (package http)
TESTS=(internal/mpsc)
# ... same loop structure as kitchen/build_and_test.sh
# Windows: ODIN_TEST_THREADS=1 for test packages with concurrent tests
```

Both scripts added to `vendor/odin-http/.gitignore` (local only — submodule fork must not carry them).

**Ask user to run:**
```
git -C vendor/odin-http add .gitignore
git -C vendor/odin-http commit -m "stage0: ignore local build scripts"
git -C vendor/odin-http push
```

### odin-http CI update (Claude writes)

`vendor/odin-http/.github/workflows/ci.yml` updated to match parent repo CI quality:
- Add opt matrix: `none, minimal, size, speed, aggressive`
- Add `test` job covering `internal/mpsc`
- Add `ODIN_TEST_THREADS=1` on Windows for concurrent test packages (same pattern and comment as parent repo CI)

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

**Changes:**

`response.odin` — add to import block:
```odin
import list "core:container/intrusive/list"
```

`response.odin` — `Response` struct, insert `node` as the very first field, add `async_state` after existing fields:
```odin
Response :: struct {
    node:        list.Node,   // intrusive MPSC node — must be first field
    // ... existing fields unchanged ...
    async_state: rawptr,      // nil = sync, non-nil = async pending
}
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
async_pending: int,               // atomic; incremented by go_async, decremented after resume handler
```

**No logic changes.** New fields are zero-valued at startup — safe.

**Ask user to run:**
```
git -C vendor/odin-http add response.odin server.odin
git -C vendor/odin-http commit -m "stage1: add async fields to Response, Connection, Server_Thread"
git -C vendor/odin-http push
```

**Ask user to run (parent repo):**
```
git add vendor/odin-http
git commit -m "stage1: update odin-http submodule pointer"
git push
```

**Exit criteria:** `bash kitchen/build_and_test_debug.sh` green → `bash kitchen/build_and_test.sh` green. All existing tests pass.

**Status entry:** record result in `impl_status.md`.

---

## Stage 2 — Wire Fields + Resume Loop (submodule)

**Goal:** Set `owning_thread` at accept time. Insert stall-aware resume loop after `nbio.tick()`. Modify shutdown exit condition.

**Files changed:** `vendor/odin-http/server.odin`

**Changes:**

`on_accept` proc — one line added:
```odin
c.owning_thread = td
```

`_server_thread_init` event loop — after `nbio.tick()`, insert:
```odin
// Resume loop — stall-aware, non-blocking, io thread only
for {
    res := mpsc.pop(&td.resume_queue)
    if res == nil {
        if mpsc.length(&td.resume_queue) == 0 { break }
        continue  // stall: producer linked head but not yet set next — retry
    }
    context.temp_allocator = virtual.arena_allocator(&res.connection.temp_allocator)
    handler := res.connection.server.handler
    handler.handle(&handler, res.connection.req, res)
    intrinsics.atomic_add(&td.async_pending, -1)
    if res.async_state != nil {
        log.warn("async handler left async_state non-nil after resume — cleared")
        res.async_state = nil
    }
}
```

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
git -C vendor/odin-http commit -m "stage2: set owning_thread on accept; add resume loop; fix shutdown exit"
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

**Goal:** Add the two public procs. Add disconnect guard. Existing sync path unchanged.

**Files changed/created:** `vendor/odin-http/resume.odin` (new), `vendor/odin-http/response.odin`

Create `vendor/odin-http/resume.odin` as a new file with the content below.

**`resume.odin` (new file):**
```odin
package http

import mpsc  "internal/mpsc"
import nbio  "core:nbio"
import "base:intrinsics"

// go_async marks the response as async and increments the pending counter.
// Call from the handler first call or body callback — io thread only.
go_async :: proc(res: ^Response, state: rawptr) {
    res.async_state = state
    intrinsics.atomic_add(&res.connection.owning_thread.async_pending, 1)
}

// resume signals the owning io thread that async work is complete.
// Any thread may call. After this call do not touch res — io thread owns it.
resume :: proc(res: ^Response) {
    if res == nil { return }
    td := res.connection.owning_thread
    msg: Maybe(^Response) = res
    if mpsc.push(&td.resume_queue, &msg) {
        nbio.wake_up(td.event_loop)
    }
}
```

`response.odin` — `response_send` proc, top of function:
```odin
if conn.state >= .Closing || conn.state == .Will_Close {
    clean_request_loop(conn)
    return
}
```

**Ask user to run:**
```
git -C vendor/odin-http add resume.odin response.odin
git -C vendor/odin-http commit -m "stage3: add go_async/resume API; add disconnect guard in response_send"
git -C vendor/odin-http push
```

**Ask user to run (parent repo):**
```
git add vendor/odin-http
git commit -m "stage3: update odin-http submodule pointer"
git push
```

**Exit criteria:** `bash kitchen/build_and_test_debug.sh` green → `bash kitchen/build_and_test.sh` green. All existing tests pass.

**Status entry:** record result in `impl_status.md`.

---

## Stage 4 — Examples + Tests (parent repo)

**Goal:** Demonstrate and verify the new API end-to-end. Thin tests — no heavy logic in examples.

**Files created:**
- `examples/async/direct_async.odin` — handler goes async without body (skeleton from §13a of design doc)
- `examples/async/body_async.odin` — handler goes async after body read (skeleton from §13b of design doc)
- `tests/functional/async/direct_async_test.odin` — starts example server, POSTs, asserts response
- `tests/functional/async/body_async_test.odin` — same for body path

**Pattern:** follows `tests/functional/echo_test.odin` — `example_*_start` / `example_*_stop`, ephemeral port, `http_cs.Post_Client`.

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
git commit -m "stage4: async examples and functional tests"
git push
```

**Exit criteria:** `bash kitchen/build_and_test_debug.sh` green → `bash kitchen/build_and_test.sh` green. All existing tests pass. New async tests pass.

**Status entry:** record result in `impl_status.md`.

---

## Stage 5 — Submodule Pointer Update + Polish

**Goal:** Parent repo points to the final submodule commit. Final check of all stages.

**Actions:**
1. Verify submodule HEAD is at Stage 3 commit.
2. Update submodule pointer in parent repo.
3. Run both kitchen scripts one final time — must be fully green.

**Ask user to run:**
```
git add vendor/odin-http
git commit -m "stage5: update odin-http submodule to async-handlers implementation"
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
| Git remote | Disabled. No push/pull. |
| Git operations | Claude shows all commands (commit, push, etc.). User decides which to run. Claude never runs git. |
| Submodule changes | Committed inside `vendor/odin-http` separately. |
| Stage verification | Debug build first → if green → full build all modes. |
| New examples | `examples/async/` subfolder. |
| New tests | `tests/functional/async/` subfolder. |
