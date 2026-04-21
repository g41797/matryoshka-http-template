//+test
package test_async

import http "../../../vendor/odin-http"
import client "../../../vendor/odin-http/client"
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

Stress_Client_Data :: struct {
        wg:   ^sync.Wait_Group,
        port: int,
}

@(private)
stress_client_thread :: proc(t: ^thread.Thread) {
        cd := (^Stress_Client_Data)(t.data)
        defer sync.wait_group_done(cd.wg)

        req: client.Request
        client.request_init(&req, .Get)
        defer client.request_destroy(&req)

        url := fmt.tprintf("http://127.0.0.1:%d/", cd.port)
        res, err := client.request(&req, url)
        if err == nil {
                client.response_destroy(&res)
        }
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

        CONCURRENCY :: 10
        wg: sync.Wait_Group
        sync.wait_group_add(&wg, CONCURRENCY)

        cds := make([]Stress_Client_Data, CONCURRENCY)
        client_threads := make([]^thread.Thread, CONCURRENCY)
        defer delete(cds)
        defer delete(client_threads)

        for i in 0..<CONCURRENCY {
                cds[i] = Stress_Client_Data{wg = &wg, port = port}
                th := thread.create(stress_client_thread)
                th.data = &cds[i]
                th.init_context = context
                thread.start(th)
                client_threads[i] = th
        }

        sync.wait(&wg)

        for th in client_threads {
                thread.join(th)
                thread.destroy(th)
        }

        cs.base_server_shutdown(ptr)
        cs.base_server_wait(ptr, 5 * time.Second)

        for th in state.threads {
                thread.join(th)
                thread.destroy(th)
        }

        free(ptr, context.allocator)
}
