//+test
package test_async

import http "http:."
import cs "../../../http_cs"
import "core:testing"
import "core:time"
import "core:thread"
import "core:sync"

N :: 3

Shutdown_Work :: struct {
	done_count:    int,
	mark_async_wg: sync.Wait_Group,
	mu:            sync.Mutex,
	bg_threads:    [dynamic]^thread.Thread,
}

shutdown_background_proc :: proc(t: ^thread.Thread) {
	res := (^http.Response)(t.data)
	work := (^Shutdown_Work)(res.async_state)
	time.sleep(100 * time.Millisecond)
	sync.mutex_lock(&work.mu)
	work.done_count += 1
	sync.mutex_unlock(&work.mu)
	http.resume(res)
}

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

Shutdown_Server :: struct {
	using base: cs.Base_Server,
}

Shutdown_Client_Data :: struct {
	port: int,
}

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

@(test)
test_graceful_shutdown_async :: proc(t: ^testing.T) {
	work := Shutdown_Work{}
	work.bg_threads = make([dynamic]^thread.Thread, 0, N, context.allocator)
	defer delete(work.bg_threads)
	sync.wait_group_add(&work.mark_async_wg, N)

	ptr := new(Shutdown_Server, context.allocator)
	if !testing.expect(t, ptr != nil, "alloc failed") { return }

	cs.base_server_init(ptr, context.allocator)
	ptr.route_handler = http.Handler{handle = shutdown_handler, user_data = &work}

	if !testing.expect(t, cs.base_server_start(ptr), "server failed to start") {
		free(ptr, context.allocator)
		return
	}

	cd := Shutdown_Client_Data{port = ptr.port.(int)}

	// Send N requests in another thread so we can trigger shutdown while they are pending.
	client_th := thread.create(shutdown_client_thread)
	client_th.data = &cd
	client_th.init_context = context
	thread.start(client_th)

	// Wait until all N handlers have called mark_async before triggering shutdown.
	sync.wait(&work.mark_async_wg)

	start_shutdown := time.now()
	cs.base_server_shutdown(ptr)
	cs.base_server_wait(ptr, 5 * time.Second)
	duration := time.since(start_shutdown)

	testing.expectf(t, work.done_count == N, "all %d background tasks should have finished before shutdown", N)
	testing.expect(t, duration >= 50 * time.Millisecond, "shutdown should have waited for pending async work")

	thread.join(client_th)
	thread.destroy(client_th)

	for th in work.bg_threads {
		thread.join(th)
		thread.destroy(th)
	}

	free(ptr, context.allocator)
}
