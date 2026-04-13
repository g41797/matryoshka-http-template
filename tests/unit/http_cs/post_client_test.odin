package test_unit_http_cs

import cs "../../../http_cs/"
import "core:testing"

@(test)
test_http_cs_nop :: proc(t: ^testing.T) {
	testing.expect(t, false == false, "")
}

// Uses http://scooterlabs.com/echo as web server for unit tests
// See description https://www.cantoni.org/2012/01/08/simple-webservice-echo-test/
@(test)
test_Post_Client :: proc(t: ^testing.T) {
	pc := cs.new_Post_Client(context.allocator)
	testing.expect(t, pc != nil, "new_Post_Client should return non-nil")


	pc^.host_or_ip = "scooterlabs.com"
	pc^.port = 80
	pc^.path = "echo"

	s := "Hello, World!"
	append(&pc^.req_body, ..transmute([]u8)(s))

	cs.post_req_resp(pc)
	testing.expect(t, pc^.status == true, "post_req_resp should return true")
	testing.expect(t, len(pc^.resp_body) > 0, "post_req_resp response len should be > 0")


	cs.free_Post_Client(pc)
}

@(test)
test_Post_Client_on_thread :: proc(t: ^testing.T) {
	pc := cs.new_Post_Client(context.allocator)
	testing.expect(t, pc != nil, "new_Post_Client should return non-nil")


	pc^.host_or_ip = "scooterlabs.com"
	pc^.port = 80
	pc^.path = "echo"

	s := "Hello, World!"

	for _ in 0 ..< 10 {
		clear(&pc^.req_body)
		append(&pc^.req_body, ..transmute([]u8)(s))

		testing.expect(t, cs.run_on_thread(pc) == true, "run_on_thread should return true")
		testing.expect(t, cs.wait_thread(pc) == true, "wait_thread should return true")

		testing.expect(t, pc^.status == true, "post_req_resp should return true")
		testing.expect(t, len(pc^.resp_body) > 0, "post_req_resp response len should be > 0")
	}

	cs.free_Post_Client(pc)
}
