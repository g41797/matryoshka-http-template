//+test
package test_async

import http "http:."
import cs "../../../http_cs"
import "core:testing"
import "core:time"
import "core:thread"
import "core:net"
import "core:sync"

Disconnect_Work :: struct {
        resumed:       ^bool,
        mark_async_wg: sync.Wait_Group,
        resumed_wg:    sync.Wait_Group,
        bg_thread:     ^thread.Thread,
}

disconnect_background_proc :: proc(t: ^thread.Thread) {
        res := (^http.Response)(t.data)
        work := (^Disconnect_Work)(res.async_state)

        // Simulate work; client will disconnect while this runs.
        time.sleep(100 * time.Millisecond)

        http.resume(res)
        work.resumed^ = true
        sync.wait_group_done(&work.resumed_wg)
}

disconnect_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
        if res.async_state == nil {
                work := (^Disconnect_Work)(h.user_data)
                http.mark_async(h, res, work)
                sync.wait_group_done(&work.mark_async_wg)

                t := thread.create(disconnect_background_proc)
                t.data = res
                work.bg_thread = t
                thread.start(t)
                return
        }

        defer { res.async_state = nil }
        // This might fail because client disconnected, which is what we want to test.
        http.respond_plain(res, "you shouldn't see this")
}

Disconnect_Server :: struct {
        using base: cs.Base_Server,
}

@(test)
test_client_disconnect_async :: proc(t: ^testing.T) {
        resumed := false
        work := Disconnect_Work{resumed = &resumed}
        sync.wait_group_add(&work.mark_async_wg, 1)
        sync.wait_group_add(&work.resumed_wg, 1)

        h := http.Handler{
                handle    = disconnect_handler,
                user_data = &work,
        }

        ptr := new(Disconnect_Server, context.allocator)
        if !testing.expect(t, ptr != nil, "alloc failed") { return }

        cs.base_server_init(ptr, context.allocator)
        ptr.route_handler = h

        if !testing.expect(t, cs.base_server_start(ptr), "server failed to start") {
                free(ptr, context.allocator)
                return
        }

        // Simulate client disconnect using low-level TCP.
        endpoint := net.Endpoint{address = net.IP4_Loopback, port = ptr.port.(int)}
        sock, err := net.dial_tcp(endpoint)
        if err != nil {
                testing.expect(t, err == nil, "failed to connect")
                cs.base_server_shutdown(ptr)
                cs.base_server_wait(ptr, 5 * time.Second)
                cs.base_server_destroy(ptr)
                return
        }

        net.send_tcp(sock, transmute([]byte)string("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))

        // Wait until handler has called mark_async, then close the socket.
        sync.wait(&work.mark_async_wg)
        net.close(sock)

        // Wait for background proc to call resume.
        sync.wait(&work.resumed_wg)

        testing.expect(t, resumed, "background work should have called resume")

        cs.base_server_shutdown(ptr)
        thread.join(work.bg_thread)
        thread.destroy(work.bg_thread)
        cs.base_server_destroy(ptr)
}
