//+test
package test_async

import http "../../../vendor/odin-http"
import "core:testing"
import "core:time"
import "core:thread"
import "core:net"

Disconnect_Work :: struct {
	resumed: ^bool,
}

disconnect_background_proc :: proc(t: ^thread.Thread) {
	res := (^http.Response)(t.data)
	work := (^Disconnect_Work)(res.async_state)

	// Wait for client to disconnect.
	time.sleep(100 * time.Millisecond)
	
	http.resume(res)
	work.resumed^ = true
}

disconnect_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		work := (^Disconnect_Work)(h.user_data)
		http.mark_async(h, res, work)

		t := thread.create(disconnect_background_proc)
		t.data = res
		thread.start(t)
		return
	}

	// This might fail because client disconnected, which is what we want to test.
	http.respond_plain(res, "you shouldn't see this")
}

@(test)
test_client_disconnect_async :: proc(t: ^testing.T) {
	server: http.Server
	resumed := false
	
	h := http.Handler{
		handle = disconnect_handler,
		user_data = &resumed,
	}

	endpoint := net.Endpoint{
		address = net.IP4_Loopback,
		port = 18084,
	}

	http.listen(&server, endpoint)
	server_th := thread.create_and_start_with_poly_data2(&server, h, proc(s: ^http.Server, h: http.Handler) {
		http.serve(s, h)
	})

	time.sleep(50 * time.Millisecond)

	// Simulate client disconnect using low-level TCP.
	sock, err := net.dial_tcp(endpoint)
	if err != nil {
		testing.expect(t, err == nil, "failed to connect")
		return
	}
	
	net.send_tcp(sock, transmute([]byte)string("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
	
	// Wait a bit then close the socket before the server resumes.
	time.sleep(30 * time.Millisecond)
	net.close(sock)

	// Wait for server to process the resume.
	time.sleep(150 * time.Millisecond)
	
	testing.expect(t, resumed, "background work should have called resume")
	
	http.server_shutdown(&server)
	thread.join(server_th)
	thread.destroy(server_th)
}
