# impl_plan.md — Odin Collections Conversion

**Version:** 0.6
**Status tracking:** `kitchen/docs/addendums/impl_status.md` — updated after every stage
**Workflow:** build passes → update impl_status.md → proceed to next stage
**No git commands.**
**Stage check:** `bash kitchen/build_and_test_debug.sh` — must exit 0 after code changes.
**Final check:** `bash kitchen/build_and_test.sh` — must exit 0 across all 5 levels.

---

## To the implementor

This plan converts the project to use Odin's collection feature for vendored dependencies (`matryoshka` and `odin-http`). This removes relative path imports and enables a "native" development experience.

**Collections Defined:**
- `matryoshka`: `vendor/matryoshka`
- `http`: `vendor/odin-http`

---

## Stage 0 — Protocol Setup

1.  Overwrite `kitchen/docs/addendums/impl_plan.md` with this content.
2.  Append the "Plan v0.6" header and "Stage 0: PASS" to `kitchen/docs/addendums/impl_status.md`.

---

## Stage 1 — Infrastructure & Tools

### 1a. Create `ols.json` at project root
```json
{
    "$schema": "https://raw.githubusercontent.com/DanielGavin/ols/master/misc/ols.schema.json",
    "collections": [
        {
            "name": "http",
            "path": "vendor/odin-http"
        },
        {
            "name": "matryoshka",
            "path": "vendor/matryoshka"
        }
    ]
}
```

### 1b. Update `kitchen/build_and_test.sh` & `kitchen/build_and_test_debug.sh`
Add `COLLECTIONS="-collection:matryoshka=vendor/matryoshka -collection:http=vendor/odin-http"` and append `$COLLECTIONS` to all `odin build`, `odin test`, and `odin doc` commands.

### 1c. Update `kitchen/tools/generate_apidocs.sh`
Update `odin doc "${DOC_ARGS[@]}"` to include `$COLLECTIONS`.

### 1d. Update `.github/workflows/ci.yml`
Update `odin build` and `odin test` steps to include the `-collection` flags.

---

## Stage 2 — VS Code Configuration

### 2a. Update `.vscode/tasks.json`
Add the collection flags to the `args` array for "Build Odin", "Build Library", "Build Tests", and "Run Tests" tasks.

---

## Stage 3 — Source Migration: `matryoshka`

Update all files currently importing `matryoshka` via relative paths.
- Search for: `import .* "../.*vendor/matryoshka"`
- Replace with: `import "matryoshka"` (or keep alias if used, e.g., `import mrt "matryoshka"`).

Affected files (at minimum):
- `handlers/bridge.odin`
- `pipeline/spawn.odin`
- `pipeline/wiring.odin`
- `examples/pipeline.odin`
- `examples/echo.odin`
- `examples/multi_worker.odin`
- `pipeline/types.odin`
- `pipeline/master.odin`
- `tests/unit/pipeline/master_test.odin`
- `tests/unit/handlers/bridge_test.odin`

---

## Stage 4 — Source Migration: `odin-http`

Update all files currently importing `odin-http` via relative paths.

### 4a. Core `http` imports
- Replace `import http "../.*vendor/odin-http"` with `import http "http"`.

### 4b. `client` sub-package imports
- Replace `import "../.*vendor/odin-http/client"` with `import "http:client"`.

Affected files (at minimum):
- `http_cs/post_client.odin`
- `http_cs/helpers.odin`
- `handlers/handler.odin`
- `handlers/bridge.odin`
- `http_cs/base_server.odin`
- `examples/pipeline.odin`
- `tests/functional/async/disconnect_test.odin`
- `tests/functional/async/shutdown_test.odin`
- `tests/functional/async/stress_test.odin`
- `examples/async/direct_async.odin`
- `examples/async/split_async.odin`
- `examples/async/body_async.odin`
- `tests/functional/async/misuse_test.odin`

---

## Stage 5 — Documentation Addendums

Update code snippets in the following files:
- `kitchen/docs/addendums/async-handlers-for-dummies.md`
- `kitchen/docs/addendums/async-handlers.md`

---

## Stage 6 — Final Verification

Run `bash kitchen/build_and_test.sh` to ensure all 5 optimization levels pass.
Run `bash kitchen/tools/generate_apidocs.sh` to verify documentation generation.
