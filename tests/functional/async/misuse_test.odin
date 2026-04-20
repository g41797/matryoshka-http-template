//+test
package test_async

import http "../../../vendor/odin-http"
import client "../../../vendor/odin-http/client"
import "core:testing"
import "core:time"
import "core:thread"
import "core:net"
import "base:intrinsics"

// 1. Double Resume
double_resume_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		http.mark_async(h, res, rawptr(uintptr(0xdeadbeef)))
		http.resume(res)
		http.resume(res) // Second resume - should be ignored or handled by MPSC
		return
	}
	defer { res.async_state = nil }
	http.respond_plain(res, "ok")
}

@(test)
test_double_resume :: proc(t: ^testing.T) {
	server: http.Server
	h := http.Handler{handle = double_resume_handler}
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = 18086}

	http.listen(&server, endpoint)
	server_th := thread.create_and_start_with_poly_data2(&server, h, proc(s: ^http.Server, h: http.Handler) {
		http.serve(s, h)
	})

	time.sleep(50 * time.Millisecond)
	
	req: client.Request
	client.request_init(&req, .Get)
	defer client.request_destroy(&req)
	res, _ := client.request(&req, "http://127.0.0.1:18086/")
	client.response_destroy(&res)

	http.server_shutdown(&server)
	thread.join(server_th)
	thread.destroy(server_th)
}

// 2. Missing cancel_async (Demonstrates the bug/hang)
// We won't actually run this as a test that must pass, because it hangs.
// But we could test it with a timeout.

// 3. Forgotten async_state = nil (Safety net test)
forgotten_nil_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		http.mark_async(h, res, rawptr(uintptr(0xdeadbeef)))
		http.resume(res)
		return
	}
	// res.async_state = nil // FORGOTTEN!
	http.respond_plain(res, "forgotten")
}

@(test)
test_forgotten_nil_safety_net :: proc(t: ^testing.T) {
	server: http.Server
	h := http.Handler{handle = forgotten_nil_handler}
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = 18087}

	http.listen(&server, endpoint)
	server_th := thread.create_and_start_with_poly_data2(&server, h, proc(s: ^http.Server, h: http.Handler) {
		http.serve(s, h)
	})

	time.sleep(50 * time.Millisecond)
	
	req: client.Request
	client.request_init(&req, .Get)
	defer client.request_destroy(&req)
	res, _ := client.request(&req, "http://127.0.0.1:18087/")
	client.response_destroy(&res)

	// If the safety net works, async_pending will be 0 and shutdown will succeed.
	http.server_shutdown(&server)
	
	// Use a timeout for the join.
	done := false
	thread.create_and_start_with_poly_data2(server_th, &done, proc(th: ^thread.Thread, done: ^bool) {
		thread.join(th)
		done^ = true
	})
	
	time.sleep(200 * time.Millisecond)
	testing.expect(t, done, "shutdown should succeed despite forgotten nil (safety net)")
	
	thread.destroy(server_th)
}
