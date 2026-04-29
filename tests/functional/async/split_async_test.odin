//+test
// Smoke test for the async machinery.
// Uses the "Split Handler" pattern: mark_async + resume called from the same thread.
package test_async

import cs "../../../http_cs"
import "core:mem"
import "core:testing"
import http "http:."
import ex "http:examples/async"

@(test)
test_split_async_smoke :: proc(t: ^testing.T) {
	app := split_async_start(0, context.allocator)
	if !testing.expect(t, app != nil, "split_async_start failed") {
		return
	}
	defer split_async_stop(app)

	url := cs.build_url("127.0.0.1", app.port.(int), "/", context.temp_allocator)

	N :: 3
	clients: cs.Post_Clients
	cs.post_clients_init(&clients, N, context.allocator)
	defer cs.post_clients_destroy(&clients)

	for i in 0 ..< N {
		cs.post_clients_set_task(&clients, i, url, transmute([]u8)string("ping"))
	}
	cs.post_clients_run(&clients)

	for i in 0 ..< N {
		if !testing.expectf(
			t,
			cs.post_clients_was_successful(&clients, i),
			"request %d should succeed",
			i,
		) {
			return
		}
		_, body, _, _ := cs.post_clients_get_result(&clients, i)
		testing.expectf(t, string(body) == "pong", "request %d response should be pong", i)
	}
}

// --- Test Infrastructure ---

SplitApp :: struct {
	using base: cs.Base_Server,
}

split_async_start :: proc(port: int, alloc: mem.Allocator) -> ^SplitApp {
	s: Maybe(^SplitApp)

	for {
		ptr := new(SplitApp, alloc)
		if ptr == nil {break}
		s = ptr

		if !cs.base_server_init(ptr, alloc) {break}
		ptr.endpoint.port = port
		ptr.route_handler = http.Handler {
			handle = ex.ping_pong_handler,
		}

		if !cs.base_server_start(ptr) {break}

		break
	}

	app, ok := s.(^SplitApp)
	if !ok {return nil}
	if app.error != .none {
		split_async_stop(app)
		return nil
	}
	return app
}

split_async_stop :: proc(app: ^SplitApp) {
	if app == nil {return}
	cs.base_server_shutdown(app)
	cs.base_server_destroy(app)
}
