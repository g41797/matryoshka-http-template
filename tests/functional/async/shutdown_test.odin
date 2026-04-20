//+test
package test_async

import http "../../../vendor/odin-http"
import client "../../../vendor/odin-http/client"
import "core:testing"
import "core:time"
import "core:thread"
import "core:net"

Shutdown_Work :: struct {
	done: ^bool,
}

shutdown_background_proc :: proc(t: ^thread.Thread) {
	res := (^http.Response)(t.data)
	work := (^Shutdown_Work)(res.async_state)

	// Hold the request for a bit.
	time.sleep(100 * time.Millisecond)
	work.done^ = true

	http.resume(res)
}

shutdown_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		work := (^Shutdown_Work)(h.user_data)
		http.mark_async(h, res, work)

		t := thread.create(shutdown_background_proc)
		t.data = res
		thread.start(t)
		return
	}

	http.respond_plain(res, "done")
}

@(test)
test_graceful_shutdown_async :: proc(t: ^testing.T) {
	server: http.Server
	work_done := false
	
	h := http.Handler{
		handle = shutdown_handler,
		user_data = &work_done,
	}

	endpoint := net.Endpoint{
		address = net.IP4_Loopback,
		port = 18083,
	}

	opts := http.Default_Server_Opts
	opts.thread_count = 1

	http.listen(&server, endpoint, opts)
	
	server_th := thread.create_and_start_with_poly_data(&server, proc(s: ^http.Server) {
		http.serve(s, {}) // handler will be passed via http.serve usually, but we use a custom setup here
	})
	// Actually we need to pass the handler to serve.
	thread.destroy(server_th)
	
	server_th = thread.create_and_start_with_poly_data2(&server, h, proc(s: ^http.Server, h: http.Handler) {
		http.serve(s, h)
	})

	time.sleep(50 * time.Millisecond)

	// Send request in another thread so we can trigger shutdown while it's pending.
	client_th := thread.create_and_start(proc() {
		req: client.Request
		client.request_init(&req, .Get)
		defer client.request_destroy(&req)
		res, _ := client.request(&req, "http://127.0.0.1:18083/")
		client.response_destroy(&res)
	})

	time.sleep(30 * time.Millisecond)
	
	// Trigger shutdown while request is in "background work" phase.
	start_shutdown := time.now()
	http.server_shutdown(&server)
	
	thread.join(server_th)
	duration := time.since(start_shutdown)

	testing.expect(t, work_done, "background work should have finished")
	testing.expect(t, duration >= 50 * time.Millisecond, "shutdown should have waited for work")
	
	thread.join(client_th)
	thread.destroy(server_th)
	thread.destroy(client_th)
}
