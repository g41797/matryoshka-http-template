//+test
package test_async

import ex "../../../examples/async"
import cs "../../../http_cs"
import "core:testing"

@(test)
test_body_async :: proc(t: ^testing.T) {
	app := ex.body_async_start(0, context.allocator)
	if !testing.expect(t, app != nil, "body_async_start failed") {
		return
	}
	defer ex.body_async_stop(app)

	url := cs.build_url("127.0.0.1", app.port.(int), "/body", context.temp_allocator)

	N :: 3
	clients: cs.Post_Clients
	cs.post_clients_init(&clients, N, context.allocator)
	defer cs.post_clients_destroy(&clients)

	for i in 0..<N {
		cs.post_clients_set_task(&clients, i, url, transmute([]u8)string("async echo"))
	}
	cs.post_clients_run(&clients)

	for i in 0..<N {
		if !testing.expectf(t, cs.post_clients_was_successful(&clients, i), "request %d should succeed", i) {
			return
		}
		_, body, _, _ := cs.post_clients_get_result(&clients, i)
		testing.expectf(t, string(body) == "async echo", "request %d response should match", i)
	}
}
