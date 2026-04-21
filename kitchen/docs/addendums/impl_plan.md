# impl_plan.md — Base_Server API Normalization + Semaphore-Based Wait

**Version:** 0.2
**Design doc:** `kitchen/docs/addendums/base_server.md`
**Status tracking:** `kitchen/docs/addendums/impl_status.md` — updated after every stage
**Workflow:** build passes → update impl_status.md → proceed to next stage automatically
**No git commands.** All files are in the parent repo; user commits and pushes after implementation is complete.
**Stage verification:** `bash kitchen/build_and_test_debug.sh` — must exit 0 after code changes. `bash kitchen/build_and_test.sh` — must exit 0 as final check.

---

## To the Implementor

You are the autonomous implementor for this task. Read this section in full before touching any file.

### Context

The `Base_Server` API (in `http_cs/base_server.odin`) was implemented with
implementation-oriented names that expose mechanism rather than purpose:
`base_thread_start`, `base_thread_join`, `base_shutdown`, `base_cleanup`,
`base_route_post`, `base_route_handler`. These are renamed to purpose-oriented
names normalized into two consistent groups: `base_server_*` and `base_router_*`.

Additionally, `base_thread_join` (blocking, no timeout) is replaced by
`base_server_wait(s, timeout) -> bool` backed by a new `done: sync.Sema` field.
`ready: sync.Wait_Group` is replaced with `ready: sync.Sema` for consistency
(two semaphores, same primitive). This allows callers to detect a hung server
and eliminates the watcher-thread hack in `misuse_test.odin`.

Previous work (Stages 1–10, Base_Server refactor) is **complete and verified**.
See `impl_status.md` for the history.

### Rename Table

| Old name | New name |
|---|---|
| `base_server_init` | `base_server_init` — no change |
| `base_thread_start` | `base_server_start` |
| `base_shutdown` | `base_server_shutdown` |
| `base_thread_join` | `base_server_wait(s, timeout) -> bool` |
| `base_cleanup` | `base_server_destroy` |
| `base_router_init` | `base_router_init` — no change |
| `base_route_post` | `base_router_post` |
| `base_route_handler` | `base_router_handler` |
| `base_router_destroy` | `base_router_destroy` — no change |

### Odin Semaphore API

Verified in `/home/g41797/dev/langs/odin-dist/core/sync/primitives.odin`:

```odin
sema_post               :: proc "contextless" (s: ^Sema, count := 1)
sema_wait               :: proc "contextless" (s: ^Sema)
sema_wait_with_timeout  :: proc "contextless" (s: ^Sema, duration: time.Duration) -> bool
// returns false on timeout, true on success
```

`sync.Sema` zero value is valid — no initialization needed, no equivalent of `wait_group_add`.

### Sources of Trust

1. **`kitchen/docs/addendums/base_server.md`** — design doc. Update it in Stage 12 to reflect new names.
2. **This file (`impl_plan.md`)** — implementation specification. Follow it literally.
3. **Existing source files** — read each file before modifying it. Verify field names, import aliases, proc signatures against actual file content.

### Critical Constraint

**Never run build scripts in a loop.** A previous session crashed 32 GB RAM doing this.
One invocation → read output → fix → one invocation. Stop and report if anything is unclear.

---

## Stage 1 — `http_cs/base_server.odin`

Read the file before editing. Apply all changes below in one pass.

### 1a. Add import

Add `import "core:time"` to the import block.

### 1b. Struct `Base_Server`

Change `ready: sync.Wait_Group` → `ready: sync.Sema`

Add below it: `done:  sync.Sema`

### 1c. Private proc `base_server_thread`

Add `defer sync.sema_post(&s.done)` as the **first line** of the proc body.
This guarantees `done` fires on every exit path. The proc has no other blocking
defers, so this is safe.

Replace both occurrences of `sync.wait_group_done(&s.ready)` with `sync.sema_post(&s.ready)`.

Remove the `sync.wait_group_add(&s.ready, 1)` call — it no longer exists (moved to
`base_server_start`, now dropped entirely because Sema needs no pre-add).

Wait — `sync.wait_group_add` is called in `base_server_start`, not in `base_server_thread`.
Confirm: `base_server_thread` only calls `wait_group_done`. Simply replace those with `sema_post`.

### 1d. Rename `base_thread_start` → `base_server_start`

Remove `sync.wait_group_add(&s.ready, 1)` — Sema needs no pre-add.
Replace `sync.wait(&s.ready)` with `sync.sema_wait(&s.ready)`.
Signature and return value unchanged:
```odin
base_server_start :: proc(s: ^Base_Server) -> (ok: bool) {
    t := thread.create(base_server_thread)
    if t == nil {
        s.error = .thread_create_failed
        return false
    }
    t.data         = s
    t.init_context = context
    thread.start(t)
    s.server_thread = t
    sync.sema_wait(&s.ready)
    return s.error == .none
}
```

### 1e. Rename `base_shutdown` → `base_server_shutdown`

No logic change.

### 1f. Replace `base_thread_join` with `base_server_wait`

```odin
// Wait for server to finish. Returns false if timeout elapsed (server may still be running).
// Returns true if server finished within timeout; s.error reflects exit status.
base_server_wait :: proc(s: ^Base_Server, timeout: time.Duration) -> (ok: bool) {
    t, has := s.server_thread.(^thread.Thread)
    if !has { return true }
    if !sync.sema_wait_with_timeout(&s.done, timeout) { return false }
    thread.join(t)
    thread.destroy(t)
    return s.error == .none
}
```

### 1g. Rename `base_route_post` → `base_router_post`

No logic change.

### 1h. Rename `base_route_handler` → `base_router_handler`

No logic change.

### 1i. Replace `base_cleanup` with `base_server_destroy`

**Do NOT call `base_server_wait` here** — use blocking `sema_wait` directly (no timeout):

```odin
// Blocking wait + base_router_destroy + free(s, s.alloc).
// Must be called after base_server_shutdown.
base_server_destroy :: proc(s: ^Base_Server) {
    t, ok := s.server_thread.(^thread.Thread)
    if ok {
        sync.sema_wait(&s.done)
        thread.join(t)
        thread.destroy(t)
    }
    base_router_destroy(s)
    free(s, s.alloc)
}
```

---

## Stage 2 — `examples/echo.odin`

Read file before editing.

- `cs.base_route_post(ptr, "/echo", h)` → `cs.base_router_post(ptr, "/echo", h)`
- `cs.base_route_handler(ptr)` → `cs.base_router_handler(ptr)`
- `cs.base_thread_start(ptr)` → `cs.base_server_start(ptr)`
- `cs.base_shutdown(app)` → `cs.base_server_shutdown(app)`
- `cs.base_thread_join(app)` → `cs.base_server_wait(app, 5 * time.Second)`
- Add `import "core:time"` if not already present

---

## Stage 3 — `examples/async/body_async.odin`

Read file before editing.

- `cs.base_route_post(ptr, "/body", h)` → `cs.base_router_post(ptr, "/body", h)`
- `cs.base_route_handler(ptr)` → `cs.base_router_handler(ptr)`
- `cs.base_thread_start(ptr)` → `cs.base_server_start(ptr)`
- `cs.base_shutdown(app)` → `cs.base_server_shutdown(app)`
- `cs.base_thread_join(app)` → `cs.base_server_wait(app, 5 * time.Second)`
- Add `import "core:time"` if not already present

---

## Stage 4 — `examples/async/direct_async.odin`

Read file before editing.

- `cs.base_route_handler(ptr)` → `cs.base_router_handler(ptr)`
- `cs.base_thread_start(ptr)` → `cs.base_server_start(ptr)`
- `cs.base_shutdown(app)` → `cs.base_server_shutdown(app)`
- `cs.base_thread_join(app)` → `cs.base_server_wait(app, 5 * time.Second)`
- Add `import "core:time"` if not already present

---

## Stage 5 — `examples/async/split_async.odin`

Read file before editing.

- `cs.base_thread_start(ptr)` → `cs.base_server_start(ptr)`
- `cs.base_shutdown(app)` → `cs.base_server_shutdown(app)`
- `cs.base_cleanup(app)` → `cs.base_server_destroy(app)`

---

## Stage 6 — `tests/functional/async/misuse_test.odin`

Read file before editing.

**`test_double_resume`** — rename only:
- `cs.base_thread_start(ptr)` → `cs.base_server_start(ptr)`
- `cs.base_shutdown(ptr)` → `cs.base_server_shutdown(ptr)`
- `cs.base_thread_join(ptr)` → `cs.base_server_wait(ptr, 5 * time.Second)`

**`test_forgotten_nil_safety_net`** — watcher thread removed entirely.

Current code after `cs.base_shutdown(ptr)`:
```odin
done := false
watcher_th := thread.create_and_start_with_poly_data2(ptr, &done, proc(srv: ^Misuse_Server, done: ^bool) {
    cs.base_thread_join(srv)
    done^ = true
})
time.sleep(1000 * time.Millisecond)
testing.expect(t, done, "shutdown should succeed despite forgotten nil (cleanup guard)")
thread.join(watcher_th)
thread.destroy(watcher_th)
free(ptr, ptr.alloc)
```

Replace with:
```odin
ok := cs.base_server_wait(ptr, 1000 * time.Millisecond)
testing.expect(t, ok, "shutdown should succeed despite forgotten nil (cleanup guard)")
free(ptr, ptr.alloc)
```

Also rename `cs.base_server_init` → no change, `cs.base_thread_start` → `cs.base_server_start`,
`cs.base_shutdown` → `cs.base_server_shutdown` in this test.

Remove `import "core:time"` — no longer used after removing `time.sleep`.
Remove `import "core:thread"` — no longer used after removing watcher thread.

---

## Stage 7 — `tests/functional/async/stress_test.odin`

Read file before editing.

- `cs.base_thread_start(ptr)` → `cs.base_server_start(ptr)`
- `cs.base_shutdown(ptr)` → `cs.base_server_shutdown(ptr)`
- `cs.base_thread_join(ptr)` → `cs.base_server_wait(ptr, 5 * time.Second)`

---

## Stage 8 — `tests/functional/async/disconnect_test.odin`

Read file before editing.

- `cs.base_thread_start(ptr)` → `cs.base_server_start(ptr)`
- All `cs.base_shutdown(ptr)` → `cs.base_server_shutdown(ptr)`
- All `cs.base_thread_join(ptr)` → `cs.base_server_wait(ptr, 5 * time.Second)`

---

## Stage 9 — `tests/functional/async/shutdown_test.odin`

Read file before editing.

- `cs.base_thread_start(ptr)` → `cs.base_server_start(ptr)`
- `cs.base_shutdown(ptr)` → `cs.base_server_shutdown(ptr)`
- `cs.base_thread_join(ptr)` → `cs.base_server_wait(ptr, 5 * time.Second)`

---

## Stage 10 — `tests/functional/async/split_async_test.odin`

Read file before editing.

- `cs.base_thread_start(ptr)` → `cs.base_server_start(ptr)`
- All `cs.base_shutdown(ptr)` → `cs.base_server_shutdown(ptr)`
- All `cs.base_thread_join(ptr)` → `cs.base_server_wait(ptr, 5 * time.Second)`

---

## Stage 11 — Build verification (debug)

Run `bash kitchen/build_and_test_debug.sh` **once**.
- Green → update `impl_status.md` Stages 1–10 to PASS, proceed to Stage 12.
- Red → read error, fix only the failing file, run once more. Do NOT loop.

---

## Stage 12 — `kitchen/docs/addendums/base_server.md`

Update all occurrences of old proc names throughout:
- `base_thread_start` → `base_server_start`
- `base_shutdown` → `base_server_shutdown`
- `base_thread_join` → `base_server_wait` (note new signature with timeout)
- `base_cleanup` → `base_server_destroy`
- `base_route_post` → `base_router_post`
- `base_route_handler` → `base_router_handler`

Update the defers note near the bottom: references `base_shutdown` / `base_cleanup` →
`base_server_shutdown` / `base_server_destroy`.

Update the API reference section with `base_server_wait` new signature:
`base_server_wait :: proc(s: ^Base_Server, timeout: time.Duration) -> (ok: bool)`

---

## Stage 13 — `kitchen/docs/addendums/impl_status.md`

Append new stage entries for Stages 1–10 of this plan once each is verified green.
Update any references to old proc names in existing entries (e.g. Stage 6 mentions
`base_thread_start`).

---

## Stage 14 — Final build verification

Run `bash kitchen/build_and_test.sh` **once** (all 5 optimization levels).
Do NOT re-run in a loop. One invocation, read output, fix if needed, one more.
