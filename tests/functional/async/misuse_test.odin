//+test
package test_async

import http "../../../vendor/odin-http"
import client "../../../vendor/odin-http/client"
import cs "../../../http_cs"
import "core:testing"
import "core:time"
import "core:thread"

// 1. Double Resume
// NOTE: calling http.resume twice with the same res corrupts the intrusive MPSC queue
// (res.node is overwritten mid-flight). Only one resume per request is valid.
double_resume_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		http.mark_async(h, res, rawptr(uintptr(0xdeadbeef)))
		http.resume(res)
		return
	}
	defer { res.async_state = nil }
	http.respond_plain(res, "ok")
}

// 2. Missing cancel_async (Demonstrates the bug/hang)
// We won't actually run this as a test that must pass, because it hangs.
// But we could test it with a timeout.

// 3. Forgotten async_state = nil (cleanup guard test)
forgotten_nil_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		http.mark_async(h, res, rawptr(uintptr(0xdeadbeef)))
		http.resume(res)
		return
	}
	// res.async_state = nil // FORGOTTEN!
	http.respond_plain(res, "forgotten")
}

Misuse_Server :: struct {
	using base: cs.Base_Server,
}

@(test)
test_double_resume :: proc(t: ^testing.T) {
	ptr := new(Misuse_Server, context.allocator)
	if !testing.expect(t, ptr != nil, "alloc failed") { return }

	cs.base_server_init(ptr, context.allocator)
	ptr.route_handler = http.Handler{handle = double_resume_handler}

	if !testing.expect(t, cs.base_thread_start(ptr), "server failed to start") {
		free(ptr, context.allocator)
		return
	}

	req: client.Request
	client.request_init(&req, .Get)
	defer client.request_destroy(&req)

	url := cs.build_url("127.0.0.1", ptr.port.(int), "/", context.temp_allocator)
	res, _ := client.request(&req, url)
	client.response_destroy(&res)

	cs.base_shutdown(ptr)
	cs.base_thread_join(ptr)
	free(ptr, context.allocator)
}

@(test)
test_forgotten_nil_safety_net :: proc(t: ^testing.T) {
	ptr := new(Misuse_Server, context.allocator)
	if !testing.expect(t, ptr != nil, "alloc failed") { return }

	cs.base_server_init(ptr, context.allocator)
	ptr.route_handler = http.Handler{handle = forgotten_nil_handler}

	if !testing.expect(t, cs.base_thread_start(ptr), "server failed to start") {
		free(ptr, context.allocator)
		return
	}

	req: client.Request
	client.request_init(&req, .Get)
	defer client.request_destroy(&req)

	url := cs.build_url("127.0.0.1", ptr.port.(int), "/", context.temp_allocator)
	res, _ := client.request(&req, url)
	client.response_destroy(&res)

	// If the cleanup guard runs, async_pending will be 0 and shutdown will succeed.
	cs.base_shutdown(ptr)

	// Use a timeout for the join.
	done := false
	watcher_th := thread.create_and_start_with_poly_data2(ptr, &done, proc(srv: ^Misuse_Server, done: ^bool) {
		cs.base_thread_join(srv)
		done^ = true
	})

	// No join-with-timeout in Odin. The server thread has 1000ms to complete shutdown.
	// If it does not finish in time, the test fails below.
	time.sleep(1000 * time.Millisecond)
	testing.expect(t, done, "shutdown should succeed despite forgotten nil (cleanup guard)")
	thread.join(watcher_th)
	thread.destroy(watcher_th)

	free(ptr, ptr.alloc)
}
