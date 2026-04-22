//+test
package test_async

import ex "../../../examples/async"
import cs "../../../http_cs"
import "core:testing"

@(test)
test_direct_async :: proc(t: ^testing.T) {
	app := ex.direct_async_start(0, context.allocator)
	if !testing.expect(t, app != nil, "direct_async_start failed") {
		return
	}
	defer ex.direct_async_stop(app)

	url := cs.build_url("127.0.0.1", app.port.(int), "/direct", context.temp_allocator)

	N :: 3
	clients: cs.Post_Clients
	cs.post_clients_init(&clients, N, context.allocator)
	defer cs.post_clients_destroy(&clients)

	for i in 0..<N {
		cs.post_clients_set_task(&clients, i, url, nil)
	}
	cs.post_clients_run(&clients)

	for i in 0..<N {
		if !testing.expectf(t, cs.post_clients_was_successful(&clients, i), "request %d should succeed", i) {
			return
		}
		_, body, _, _ := cs.post_clients_get_result(&clients, i)
		testing.expectf(t, string(body) == "hello from background", "request %d response should match", i)
	}
}
