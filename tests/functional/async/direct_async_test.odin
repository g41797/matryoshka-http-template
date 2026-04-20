//+test
package test_async

import ex "../../../examples/async"
import client "../../../vendor/odin-http/client"
import cs "../../../http_cs"
import "core:testing"
import "core:time"

@(test)
test_direct_async :: proc(t: ^testing.T) {
	app := ex.direct_async_start(0, context.allocator)
	if !testing.expect(t, app != nil, "direct_async_start failed") {
		return
	}
	defer ex.direct_async_stop(app)

	time.sleep(50 * time.Millisecond)

	req: client.Request
	client.request_init(&req, .Get)
	defer client.request_destroy(&req)

	url := cs.build_url("127.0.0.1", app.port, "/direct", context.temp_allocator)
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
	testing.expect(t, body_str == "hello from background", "response should match")
}
