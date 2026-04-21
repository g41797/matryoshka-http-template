//+test
package test_async

import ex "../../../examples/async"
import client "../../../vendor/odin-http/client"
import cs "../../../http_cs"
import "core:testing"
import "core:bytes"

@(test)
test_body_async :: proc(t: ^testing.T) {
	app := ex.body_async_start(0, context.allocator)
	if !testing.expect(t, app != nil, "body_async_start failed") {
		return
	}
	defer ex.body_async_stop(app)

	req: client.Request
	client.request_init(&req, .Post)
	defer client.request_destroy(&req)
	
	bytes.buffer_write_string(&req.body, "async echo")

	url := cs.build_url("127.0.0.1", app.port.(int), "/body", context.temp_allocator)
	res, err := client.request(&req, url)
	if !testing.expect(t, err == nil, "HTTP request failed") {
		return
	}
	defer client.response_destroy(&res)

	testing.expect(t, res.status == .OK, "status should be 200 OK")

	body, was_alloc, body_err := client.response_body(&res)
	testing.expect(t, body_err == nil, "body should be readable")
	defer client.body_destroy(body, was_alloc)

	body_str, ok := body.(client.Body_Plain)
	testing.expect(t, ok, "body should be plain text")
	testing.expect(t, body_str == "async echo", "response should match")
}
