//+test
package test_async

import http "../../../vendor/odin-http"
import client "../../../vendor/odin-http/client"
import "core:testing"
import "core:time"
import "core:sync"
import "core:thread"
import "core:net"
import "core:math/rand"

Stress_Work :: struct {
	id: int,
}

stress_background_proc :: proc(t: ^thread.Thread) {
	res := (^http.Response)(t.data)

	// Random delay 1-50ms.
	ms := 1 + rand.int_max(50)
	time.sleep(time.Duration(ms) * time.Millisecond)

	http.resume(res)
}

stress_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		id := 0 // strconv.parse_int(id_str) would be better but let's keep it simple
		
		work := new(Stress_Work, context.temp_allocator)
		work.id = id
		http.mark_async(h, res, work)

		t := thread.create(stress_background_proc)
		t.data = res
		thread.start(t)
		return
	}

	defer { res.async_state = nil }
	
	http.respond_plain(res, "ok")
}

@(test)
test_async_stress :: proc(t: ^testing.T) {
	server: http.Server
	h := http.Handler{handle = stress_handler}
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = 18085}

	http.listen(&server, endpoint)
	server_th := thread.create_and_start_with_poly_data2(&server, h, proc(s: ^http.Server, h: http.Handler) {
		http.serve(s, h)
	})

	time.sleep(50 * time.Millisecond)

	CONCURRENCY :: 10 
	wg: sync.Wait_Group
	sync.wait_group_add(&wg, CONCURRENCY)

	threads := make([]^thread.Thread, CONCURRENCY)
	defer delete(threads)

	for &th in threads {
		th = thread.create_and_start_with_poly_data(&wg, proc(wg: ^sync.Wait_Group) {
			defer sync.wait_group_done(wg)
			
			req: client.Request
			client.request_init(&req, .Get)
			defer client.request_destroy(&req)
			
			res, err := client.request(&req, "http://127.0.0.1:18085/")
			if err == nil {
				client.response_destroy(&res)
			}
		})
	}

	sync.wait(&wg)

	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	
	http.server_shutdown(&server)
	thread.join(server_th)
	thread.destroy(server_th)
}
