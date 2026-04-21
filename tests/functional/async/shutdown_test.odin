//+test
package test_async

import http "../../../vendor/odin-http"
import client "../../../vendor/odin-http/client"
import cs "../../../http_cs"
import "core:fmt"
import "core:testing"
import "core:time"
import "core:thread"
import "core:sync"

Shutdown_Work :: struct {
	done:          ^bool,
	mark_async_wg: sync.Wait_Group,
	bg_thread:     ^thread.Thread,
}

shutdown_background_proc :: proc(t: ^thread.Thread) {
	res := (^http.Response)(t.data)
	work := (^Shutdown_Work)(res.async_state)

	// Simulate work holding the request open.
	time.sleep(100 * time.Millisecond)
	work.done^ = true

	http.resume(res)
}

shutdown_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		work := (^Shutdown_Work)(h.user_data)
		http.mark_async(h, res, work)
		sync.wait_group_done(&work.mark_async_wg)

		t := thread.create(shutdown_background_proc)
		t.data = res
		work.bg_thread = t
		thread.start(t)
		return
	}

	defer { res.async_state = nil }
	http.respond_plain(res, "done")
}

Shutdown_Server :: struct {
	using base: cs.Base_Server,
}

Shutdown_Client_Data :: struct {
	port: int,
}

@(private)
shutdown_client_thread :: proc(t: ^thread.Thread) {
	cd := (^Shutdown_Client_Data)(t.data)
	req: client.Request
	client.request_init(&req, .Get)
	defer client.request_destroy(&req)
	url := fmt.tprintf("http://127.0.0.1:%d/", cd.port)
	res, _ := client.request(&req, url)
	client.response_destroy(&res)
}

@(test)
test_graceful_shutdown_async :: proc(t: ^testing.T) {
	work_done := false
	work := Shutdown_Work{done = &work_done}
	sync.wait_group_add(&work.mark_async_wg, 1)

	ptr := new(Shutdown_Server, context.allocator)
	if !testing.expect(t, ptr != nil, "alloc failed") { return }

	cs.base_server_init(ptr, context.allocator)
	ptr.route_handler = http.Handler{handle = shutdown_handler, user_data = &work}

	if !testing.expect(t, cs.base_thread_start(ptr), "server failed to start") {
		free(ptr, context.allocator)
		return
	}

	cd := Shutdown_Client_Data{port = ptr.port.(int)}

	// Send request in another thread so we can trigger shutdown while it's pending.
	client_th := thread.create(shutdown_client_thread)
	client_th.data = &cd
	client_th.init_context = context
	thread.start(client_th)

	// Wait until the handler has called mark_async before triggering shutdown.
	sync.wait(&work.mark_async_wg)

	start_shutdown := time.now()
	cs.base_shutdown(ptr)
	cs.base_thread_join(ptr)
	duration := time.since(start_shutdown)

	testing.expect(t, work_done, "background work should have finished before shutdown")
	testing.expect(t, duration >= 50 * time.Millisecond, "shutdown should have waited for pending async work")

	thread.join(client_th)
	thread.destroy(client_th)
	thread.join(work.bg_thread)
	thread.destroy(work.bg_thread)

	free(ptr, context.allocator)
}
