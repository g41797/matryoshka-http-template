//+test
package test_async

import http "http:."
import cs "../../../http_cs"
import "core:fmt"
import "core:testing"
import "core:time"
import "core:sync"
import "core:thread"
import "core:math/rand"

Stress_Work :: struct {
        id: int,
}

Stress_State :: struct {
        mu:      sync.Mutex,
        threads: [dynamic]^thread.Thread,
}

stress_background_proc :: proc(t: ^thread.Thread) {
        res := (^http.Response)(t.data)

        // Random delay 1-50ms to simulate concurrent async work.
        ms := 1 + rand.int_max(50)
        time.sleep(time.Duration(ms) * time.Millisecond)

        http.resume(res)
}

stress_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
        if res.async_state == nil {
                work := new(Stress_Work, context.temp_allocator)
                work.id = 0
                http.mark_async(h, res, work)

                state := (^Stress_State)(h.user_data)
                t := thread.create(stress_background_proc)
                t.data = res
                thread.start(t)
                sync.mutex_lock(&state.mu)
                append(&state.threads, t)
                sync.mutex_unlock(&state.mu)
                return
        }

        defer { res.async_state = nil }

        http.respond_plain(res, "ok")
}

Stress_Server :: struct {
        using base: cs.Base_Server,
}

@(test)
test_async_stress :: proc(t: ^testing.T) {
        state := Stress_State{}
        state.threads = make([dynamic]^thread.Thread, 0, 10, context.allocator)
        defer delete(state.threads)

        ptr := new(Stress_Server, context.allocator)
        if !testing.expect(t, ptr != nil, "alloc failed") { return }

        cs.base_server_init(ptr, context.allocator)
        ptr.route_handler = http.Handler{handle = stress_handler, user_data = &state}

        if !testing.expect(t, cs.base_server_start(ptr), "server failed to start") {
                free(ptr, context.allocator)
                return
        }

        port := ptr.port.(int)
        url := fmt.tprintf("http://127.0.0.1:%d/", port)

        CONCURRENCY :: 10
        clients: cs.Post_Clients
        cs.post_clients_init(&clients, CONCURRENCY, context.allocator)
        defer cs.post_clients_destroy(&clients)

        for i in 0..<CONCURRENCY {
                cs.post_clients_set_task(&clients, i, url, nil)
        }

        cs.post_clients_run(&clients)

        for i in 0..<CONCURRENCY {
                testing.expectf(t, cs.post_clients_was_successful(&clients, i), "task %d should succeed", i)
        }

        cs.base_server_shutdown(ptr)
        cs.base_server_wait(ptr, 10 * time.Second)

        for th in state.threads {
                thread.join(th)
                thread.destroy(th)
        }

        free(ptr, context.allocator)
}
