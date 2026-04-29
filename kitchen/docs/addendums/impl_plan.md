# impl_plan.md — Rewrite doc.odin, Example Comments, and pr_report.md

**Version:** 0.9
**Status tracking:** `kitchen/docs/addendums/impl_status.md` — updated after every stage
**Workflow:** build passes → update impl_status.md → proceed to next stage
**No git commands.**
**No build check needed for Stages 1–5** — comment/doc changes only.
**Final check:** `bash kitchen/build_and_test_debug.sh` — must exit 0 at Stage 6.

---

## Context

Plan v0.8 produced skeleton versions of three deliverables. This plan rewrites them
using existing markdown documentation as source material — extracting real explanations
and adapting them, not generating new AI text.

**Deliverables:**
1. `deps/odin-http/examples/async/doc.odin` — package-level documentation
2. Comments in all three example files in `deps/odin-http/examples/async/`
3. `kitchen/docs/addendums/pr_report.md` — PR body for laytan

**Source documents to extract from:**
- `kitchen/docs/addendums/async-handlers-for-dummies.md` — for doc.odin and example comments
- `kitchen/docs/addendums/async-handlers-for-advanced.md` — for allocator/threading rules
- `kitchen/docs/addendums/async-handlers.md` — for pr_report.md (motivation, requirements, architecture, API)

**Filtering rule (applies to every deliverable):**
Strip all references to Matryoshka (`matryoshka.*`, `mbox_*`, pipeline inbox, `Work_Message`),
`Base_Server`, `http_cs`, `Post_Clients`, or any other parent-repo infrastructure.
These docs target either odin-http users in general (doc.odin, comments) or laytan
specifically (pr_report.md). Neither audience knows or cares about the parent repo.

---

## Stage 0 — Protocol Setup

1. Overwrite `kitchen/docs/addendums/impl_plan.md` with this content.
2. Append Plan v0.9 header + Stage 0 PASS to `kitchen/docs/addendums/impl_status.md`.

---

## Stage 1 — Rewrite `doc.odin`

**File:** `deps/odin-http/examples/async/doc.odin`

Read the current file first. Then rewrite the block comment. Keep `package async_examples`
at the end. No `import` statements.

**Content to write — extract and adapt from these sources:**

### 1.1 The problem (from advanced §1)
One short paragraph: the IO thread runs the event loop — blocking it for slow work
(database, file, external API) stalls all other requests on that thread. Async handlers
fix this by letting the handler return immediately and re-enter later with the result.
No matryoshka reference. Generic slow-work framing only.

### 1.2 The split handler pattern (from dummies §2 and §4)
One handler proc, two invocations, distinguished by `res.async_state == nil`.
Show the skeleton:

```odin
my_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
    if res.async_state == nil {
        // Part 1 (IO thread): allocate work, mark_async, start background work, return.
    } else {
        // Part 2 (IO thread, resume call): read result, respond, clean up.
    }
}
```

### 1.3 The three variants (brief, one sentence each + key line)
- `without_body_async.odin` — no body needed; Part 1 calls `mark_async` then starts a background thread
- `with_body_async.odin` — body read first; the body callback calls `mark_async` then starts a background thread
- `ping_pong.odin` — no background thread; callback calls `mark_async` + `resume` on the IO thread in the same tick

### 1.4 Thread usage note (from dummies §5)
These examples use `thread.create` per request to show the flow clearly.
**This is a learning pattern, not for production.** A real server uses a worker pool
or pipeline; only the glue code that signals completion calls `http.resume(res)`.

### 1.5 The three API procs (from async-handlers.md §4 comments, adapted)
- `mark_async(h, res, work)` — records the exact handler for Part 2 (middleware-safe)
  and increments `async_pending`; call this **before** starting background work
- `cancel_async(res)` — rolls back `mark_async` when background work fails to start;
  decrements `async_pending`; **must** be paired with `http.respond` — omitting either
  causes a hung server (counter never reaches zero) or a hung client
- `resume(res)` — called from the background thread when work is done; pushes `res`
  onto the per-IO-thread MPSC queue and wakes the IO thread; call **exactly once**;
  after this call, do not touch `res` or any connection field

### 1.6 Ownership table (from dummies §8)

```
Phase                        | Owner        | Background thread may
-----------------------------|--------------|-----------------------------------------------
Part 1 (first call)          | IO thread    | —
Background work              | Bkg thread   | read/write work struct fields; call resume once
Part 2 (resume call)         | IO thread    | —
```

In the background phase: do not read or write `res` fields directly. Do not call any
`http.*` proc except `http.resume`. Do not allocate from `context.temp_allocator`
(the per-connection arena is not thread-safe — any allocation from a background thread
is a data race).

### 1.7 Hard rules (from dummies §8 and advanced §7, adapted, no matryoshka)
Numbered list. For each rule, include the WHY in one sentence:

1. Call `mark_async` before starting background work — if work starts first and calls
   `resume` before `mark_async`, `async_pending` is incremented after the decrement
   and the server never shuts down.
2. If background work fails to start: call `cancel_async` AND `http.respond` — omitting
   `cancel_async` leaves `async_pending` permanently incremented; omitting `http.respond`
   silently drops the request.
3. Call `resume` exactly once — zero calls lose the request forever; two calls corrupt
   the connection.
4. Set `res.async_state = nil` before Part 2 returns — the server uses this field to
   detect when the async cycle is finished. Use `defer { res.async_state = nil }`.
5. Part 2 runs even if the client disconnected — always clean up (join thread, free work).
6. Store `res.async_handler = h` before calling `http.body()` if the body callback needs
   to call `mark_async` — the callback receives only `user_data`, not `h`.

### Stage 1 acceptance criteria
- `doc.odin` contains all six sections above.
- No `import` statement.
- No reference to Matryoshka, `Base_Server`, `http_cs`, or any parent-repo type.
- "Learning pattern, not for production" note is present.
- The ownership table is present.
- Each rule includes its WHY.

---

## Stage 2 — Rewrite Comments in `without_body_async.odin`

Read the current file. Replace comments using dummies §4 as the primary source.
Do not change any code — only comments.

**What to add/replace:**

- **Before `if res.async_state == nil`:** `// Part 1: first call on the IO thread.`

- **Before `http.mark_async`:**
  ```
  // mark_async before thread.start — if the thread calls resume before mark_async,
  // async_pending is incremented after the decrement and shutdown hangs forever.
  ```

- **In the `if t == nil` block:**
  ```
  // Two steps are both required on Part 1 failure:
  // 1. cancel_async — rolls back async_pending; without this the server never shuts down.
  // 2. http.respond — without this the client waits forever.
  ```

- **Before Part 2:** `// Part 2: resume call on the IO thread.`

- **Before or inside the defer block:**
  ```
  // res.async_state = nil tells the server the async cycle is finished.
  // thread.join here is fast — background thread already called resume, meaning it finished.
  ```

- **In `without_body_background_proc`, before save/restore:**
  ```
  // context.temp_allocator is the per-connection arena — not thread-safe.
  // Save and restore so this thread's allocation does not corrupt the IO thread's arena.
  ```

- **Before `http.resume`:**
  ```
  // Store all results in work BEFORE calling resume.
  // After resume returns, the IO thread owns res — do not touch res or work.
  ```

### Stage 2 acceptance criteria
- No code lines changed, only comments.
- All seven comment points above are present.
- No matryoshka or parent-repo references.

---

## Stage 3 — Rewrite Comments in `with_body_async.odin`

Read the current file. Replace/add comments using dummies §4 as the primary source.

**What to add/replace:**

- **Before `res.async_handler = h`:**
  ```
  // Store h now — the body callback receives user_data (res), not h.
  // Without this, the callback cannot call mark_async with the correct handler.
  ```

- **Before `http.body(...)`:** `// Part 1: start async body read; handler returns immediately.`

- **Before Part 2 branch:** `// Part 2: resume call on the IO thread.`

- **Before/inside Part 2 defer:**
  ```
  // thread.join is fast here — background thread already called resume (it finished).
  // res.async_state = nil is mandatory before returning from Part 2.
  ```

- **Above `body_callback`:**
  ```
  // body_callback runs on the IO thread after the full body is received.
  // This is still Part 1 — the IO thread has not been released yet.
  ```

- **Before `http.mark_async` in callback:**
  ```
  // mark_async before thread.start — same ordering rule as the direct pattern.
  ```

- **In the `if t == nil` block in callback:** same two-step explanation as Stage 2.

- **In `body_background_proc`, before save/restore:** same WHY as Stage 2.

- **Before `http.resume` in background proc:** same "store before resume" comment as Stage 2.

### Stage 3 acceptance criteria
- No code lines changed, only comments.
- All comment points above are present.
- No matryoshka or parent-repo references.

---

## Stage 4 — Rewrite Comments in `ping_pong.odin`

Read the current file. This is the same-thread split pattern — no background thread.

**What to add/replace:**

- **Above `ping_pong_handler`:**
  ```
  // Same-thread split pattern: both mark_async and resume are called on the IO thread
  // inside the body callback. No background thread is created.
  // Part 2 runs in the same event-loop tick as the callback.
  ```

- **Before `res.async_handler = h`:** same explanation as Stage 3.

- **Before Part 2 branch:** `// Part 2: resume call on the IO thread (same tick as callback).`

- **Above `ping_pong_callback`:**
  ```
  // ping_pong_callback runs on the IO thread inside scanner_on_read.
  // context.temp_allocator is already set to the connection arena — no save/restore needed.
  // mark_async + resume called synchronously here; no other thread is involved.
  ```

- **Before `http.mark_async` in callback:**
  ```
  // mark_async before resume — same ordering invariant as all patterns.
  ```

- **Before `http.resume`:**
  ```
  // resume on the IO thread: pushes res onto the queue and wakes the event loop.
  // The loop processes it on the next tick, re-entering the handler at Part 2.
  ```

### Stage 4 acceptance criteria
- No code lines changed, only comments.
- All comment points above are present.
- "Learning pattern / not for production" NOT needed here — ping_pong has no thread.
- No matryoshka or parent-repo references.

---

## Stage 5 — Rewrite `pr_report.md`

**File:** `kitchen/docs/addendums/pr_report.md`

Write for laytan — he knows the odin-http codebase well. Skip basics. Focus on design
reasoning, invariants, and non-obvious decisions. No matryoshka references.

### Section 1 — Summary (4–5 sentences)
What the PR adds, how resume works (MPSC + `nbio.wake_up`, same primitive as `server_shutdown`),
what's included (three examples, three non-async fixes), what `internal/mpsc` is.

### Section 2 — The Problem (adapted from async-handlers.md §1 — NO matryoshka)
Any handler doing slow work blocks the IO thread. With a small fixed thread pool, this
caps throughput to `thread_count` concurrent blocking requests.
Goal: handlers return immediately; same handler re-invoked with result; no signature changes.

### Section 3 — The Split Handler Pattern
One handler proc, two invocations, `res.async_state` as the guard. Show the skeleton
with `mark_async` and `defer { res.async_state = nil }`. Explain `async_state` as the
sole bridge between Part 1 and Part 2.

### Section 4 — Flow Diagrams (ASCII art, three separate diagrams)

**Diagram A — Direct (without_body_async.odin):**
Part 1 → `mark_async` + `thread.start` → IO thread free → background work →
`http.resume` → MPSC push + `nbio.wake_up` → IO thread dequeues → Part 2 → respond.
Show `async_pending` increment/decrement.

**Diagram B — Body-first (with_body_async.odin):**
Part 1 → store `async_handler` + `http.body()` → async recv → `body_callback` on IO thread →
`mark_async` + `thread.start` → IO thread free → background → `http.resume` → Part 2.

**Diagram C — Same-thread split (ping_pong.odin):**
Part 1 → `http.body()` → callback on IO thread → `mark_async` + `http.resume` (same thread,
synchronous) → Part 2 in same tick. Label: no background thread.

### Section 5 — Key Design Decisions
Extract from `async-handlers-development.md` §7:
- Why mark_async/cancel_async/resume (ordering guarantee, cancel_async for shutdown safety)
- Why MPSC (many producers, one consumer — exactly correct primitive; wake_up already exists)
- Why async_handler field (middleware-safe: resume the exact handler, not chain head)
- Why intrusive MPSC (no allocation per enqueue; `#assert` guards field position)

Add memory ordering note from async-handlers.md §4: MPSC atomic ops (release in `push`,
acquire in `pop`) guarantee work struct writes visible to IO thread in Part 2.

### Section 6 — Changes: Async Functionality
Per file: `resume.odin` (new), `response.odin` (modified), `server.odin` (modified),
`internal/mpsc/` (new). For `response.odin`: mention `#assert(offset_of(Response, node) == 0)`.
For `internal/mpsc/`: pure Odin, zero dependency on odin-http or nbio, may be proposed to
Odin core separately.

### Section 7 — Changes: Non-Async Fixes (exactly three items)
1. Shutdown loop — `nbio.tick(1ms)`, only idle connections closed, `conn_handle_req` guard.
   Why: SIGBUS on macOS, memory leaks on Windows.
2. `log.errorf` → `log.warnf` in `on_response_sent`. Why: test framework treats errorf as failure.
3. Save/restore `context.temp_allocator` in resume loop. Why: stale arena → crashes under stress.
   Note: this is the actual root fix; two earlier similar assignments were redundant and reverted.

### Section 8 — Examples
Three examples, package `async_examples`. Thread-per-request note: **learning pattern only**,
not for production. Real server uses a worker pool; only glue code calls `http.resume(res)`.

### Stage 5 acceptance criteria
- All eight sections present.
- Three ASCII diagrams, one per variant; ping_pong labeled "no background thread".
- Memory ordering paragraph in Section 5.
- `#assert` mention in Section 6.
- Non-async fixes: exactly three items; reverted lines NOT mentioned.
- "Learning pattern only" note in Section 8.
- Zero references to Matryoshka, `mbox`, `Base_Server`, `http_cs`, `bridge.odin`,
  or any parent-repo type.

---

## Stage 6 — Final Documentation Update

1. Update `kitchen/docs/addendums/async-handlers-development.md` §5: append v0.9 row:
   `| v0.9 | Rewrite doc.odin, example comments, pr_report.md from source docs | All stages PASS |`

2. Update `kitchen/docs/addendums/impl_status.md`: append Plan v0.9 stage entries (Stages 0–6, PASS).

3. Run `bash kitchen/build_and_test_debug.sh` — must exit 0.

### Stage 6 acceptance criteria
- §5 history row added.
- `impl_status.md` has all 7 stage entries for v0.9.
- Build exits 0.

---

## Quality Criteria for the Implementing AI

### Writing rules
- Extract and adapt from source documents — do not invent explanations.
- Every WHY must trace to a real invariant (ordering, counter, arena safety).
- Do not use the word "safety net" — use "cleanup guard" if needed.

### Filtering (scan before writing every file)
Remove/replace: `matryoshka`, `mbox`, `pipeline_inbox`, `Work_Message`, `Base_Server`,
`http_cs`, `Post_Clients`, `post_client`, `bridge.odin`, `split-handlers.md`.

### Comment style
- Comments explain WHY, not WHAT.
- One sentence per comment is usually enough. Two sentences maximum.

### impl_status.md entry format
```
### Stage N: Title
- **Result:** PASS
- **Details:** One or two sentences describing what was done.
```
