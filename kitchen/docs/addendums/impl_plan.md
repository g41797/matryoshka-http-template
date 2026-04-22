# impl_plan.md — Upgrade 5 async tests to N > 1 clients

**Version:** 0.5
**Status tracking:** `kitchen/docs/addendums/impl_status.md` — updated after every stage
**Workflow:** build passes → update impl_status.md → proceed to next stage
**No git commands.**
**Stage check:** `bash kitchen/build_and_test_debug.sh` — must exit 0 after code changes.
**Final check:** `bash kitchen/build_and_test.sh` — must exit 0 across all 5 levels.

---

## To the implementor

Read this before touching any file.

### Context

Five async functional tests send only 1 concurrent request. N=3 clients running at the same
time gives real value: it exercises the async pending-request counter, the cleanup guard, and
graceful shutdown under actual concurrent load. N=3 matches the existing `test_Post_Client_multiple`.

`test_double_resume` stays at 1 — it tests a specific error condition, not concurrency.

### Critical rule

Never run a build script in a loop. One run → read output → fix → one run.

---

## Stage 1 — body_async_test.odin, direct_async_test.odin, split_async_test.odin

Read each file before editing. Same pattern for all three.

For each test proc:

1. Add `N :: 3` at the top of the proc.
2. Change `cs.post_clients_init(&clients, 1, ...)` → `cs.post_clients_init(&clients, N, ...)`.
3. Replace the single `cs.post_clients_set_task(&clients, 0, ...)` with a loop:
   ```odin
   for i in 0..<N {
       cs.post_clients_set_task(&clients, i, url, <body>)
   }
   ```
4. Replace the single `was_successful` + `get_result` check with a loop:
   ```odin
   for i in 0..<N {
       if !testing.expectf(t, cs.post_clients_was_successful(&clients, i), "request %d should succeed", i) {
           return
       }
       _, body, _, _ := cs.post_clients_get_result(&clients, i)
       testing.expectf(t, string(body) == <expected>, "request %d response should match", i)
   }
   ```

Body and expected values:
- `body_async`: body = `transmute([]u8)string("async echo")`, expected = `"async echo"`
- `direct_async`: body = `nil`, expected = `"hello from background"`
- `split_async`: body = `transmute([]u8)string("ping")`, expected = `"pong"`

---

## Stage 2 — misuse_test.odin (`test_forgotten_nil_cleanup_guard` only)

Read the file before editing. `test_double_resume` is NOT changed.

In `test_forgotten_nil_cleanup_guard`:

1. Add `N :: 3` constant inside the proc.
2. Change `cs.post_clients_init(&clients, 1, ...)` → `cs.post_clients_init(&clients, N, ...)`.
3. Replace the single `cs.post_clients_set_task` call with a loop:
   ```odin
   for i in 0..<N {
       cs.post_clients_set_task(&clients, i, url, nil)
   }
   ```
4. Keep the shutdown check unchanged — the cleanup guard must handle all N "forgotten"
   requests before `base_server_wait` returns.

---

## Stage 3 — shutdown_test.odin

Read the file before editing. This test needs significant rework.

The current `Shutdown_Work` has a single `done: ^bool` and `bg_thread: ^thread.Thread`.
With N concurrent requests, N background threads run at the same time.
The new design follows the pattern from `stress_test.odin`.

### 3a. Add `N` constant at package level (before the structs)

```odin
N :: 3
```

### 3b. New `Shutdown_Work` struct

Remove `done` and `bg_thread`. Replace with `done_count int`, `mu sync.Mutex`,
`bg_threads [dynamic]^thread.Thread`:

```odin
Shutdown_Work :: struct {
	done_count:    int,
	mark_async_wg: sync.Wait_Group,
	mu:            sync.Mutex,
	bg_threads:    [dynamic]^thread.Thread,
}
```

### 3c. `shutdown_background_proc`

Replace `work.done^ = true` with a mutex-protected increment:

```odin
shutdown_background_proc :: proc(t: ^thread.Thread) {
	res := (^http.Response)(t.data)
	work := (^Shutdown_Work)(res.async_state)
	time.sleep(100 * time.Millisecond)
	sync.mutex_lock(&work.mu)
	work.done_count += 1
	sync.mutex_unlock(&work.mu)
	http.resume(res)
}
```

### 3d. `shutdown_handler`

Replace `work.bg_thread = t` with a mutex-protected append to `bg_threads`:

```odin
shutdown_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		work := (^Shutdown_Work)(h.user_data)
		http.mark_async(h, res, work)
		sync.wait_group_done(&work.mark_async_wg)
		t := thread.create(shutdown_background_proc)
		t.data = res
		thread.start(t)
		sync.mutex_lock(&work.mu)
		append(&work.bg_threads, t)
		sync.mutex_unlock(&work.mu)
		return
	}
	defer { res.async_state = nil }
	http.respond_plain(res, "done")
}
```

### 3e. `shutdown_client_thread`

Change from 1 client to N. Replace `fmt.tprintf` with `cs.build_url`:

```odin
@(private)
shutdown_client_thread :: proc(t: ^thread.Thread) {
	cd := (^Shutdown_Client_Data)(t.data)
	url := cs.build_url("127.0.0.1", cd.port, "/", context.temp_allocator)
	clients: cs.Post_Clients
	cs.post_clients_init(&clients, N, context.allocator)
	defer cs.post_clients_destroy(&clients)
	for i in 0..<N {
		cs.post_clients_set_task(&clients, i, url, nil)
	}
	cs.post_clients_run(&clients)
}
```

Remove `import "core:fmt"` — no longer needed.

### 3f. `test_graceful_shutdown_async`

- Remove `work_done := false`.
- Init work:
  ```odin
  work := Shutdown_Work{}
  work.bg_threads = make([dynamic]^thread.Thread, 0, N, context.allocator)
  defer delete(work.bg_threads)
  sync.wait_group_add(&work.mark_async_wg, N)
  ```
- Remove `work.done = &work_done` from the old `Shutdown_Work` initializer.
- Replace `testing.expect(t, work_done, ...)` with:
  ```odin
  testing.expectf(t, work.done_count == N, "all %d background tasks should have finished before shutdown", N)
  ```
- Replace the single `thread.join(work.bg_thread)` / `thread.destroy(work.bg_thread)` with:
  ```odin
  for th in work.bg_threads {
  	thread.join(th)
  	thread.destroy(th)
  }
  ```

---

## Stage 4 — Build check (debug)

Run `bash kitchen/build_and_test_debug.sh` once.
- Green → update `impl_status.md` Stages 1–3 as PASS, go to Stage 5.
- Red → fix only the failing file, run once more.

---

## Stage 5 — Final build check (all levels)

Run `bash kitchen/build_and_test.sh` once.
- Green → update `impl_status.md` Stage 5 as PASS. Done.
- Red → fix, run once more.
