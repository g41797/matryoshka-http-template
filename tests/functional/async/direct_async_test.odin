//+test
package test_async

import cs "../../../http_cs"
import "core:mem"
import "core:testing"
import "core:time"
import http "http:."
import ex "http:examples/async"

@(test)
test_direct_async :: proc(t: ^testing.T) {
	app := direct_async_start(0, context.allocator)
	if !testing.expect(t, app != nil, "direct_async_start failed") {
		return
	}
	defer direct_async_stop(app)

	url := cs.build_url("127.0.0.1", app.port.(int), "/direct", context.temp_allocator)

	N :: 3
	clients: cs.Post_Clients
	cs.post_clients_init(&clients, N, context.allocator)
	defer cs.post_clients_destroy(&clients)

	for i in 0 ..< N {
		cs.post_clients_set_task(&clients, i, url, nil)
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
		testing.expectf(
			t,
			string(body) == "hello from background",
			"request %d response should match",
			i,
		)
	}
}

// --- Test Infrastructure ---

DirectApp :: struct {
	using base: cs.Base_Server,
	ctx:        ^ex.Without_Body_Context,
}

direct_async_start :: proc(port: int, alloc: mem.Allocator) -> ^DirectApp {
	s: Maybe(^DirectApp)

	for {
		ptr := new(DirectApp, alloc)
		if ptr == nil {break}
		s = ptr

		if !cs.base_server_init(ptr, alloc) {break}
		ptr.endpoint.port = port

		ctx := new(ex.Without_Body_Context, alloc)
		if ctx == nil {ptr.error = .user_error; break}
		ctx.alloc = alloc
		ptr.ctx = ctx

		h := http.Handler {
			handle    = ex.without_body_handler,
			user_data = ptr.ctx,
		}

		// direct used GET, now uses POST to match the new Base Client.
		if !cs.base_router_init(ptr) {break}
		if !cs.base_router_post(ptr, "/direct", h) {break}
		if !cs.base_router_handler(ptr) {break}
		if !cs.base_server_start(ptr) {break}

		break
	}

	app, ok := s.(^DirectApp)
	if !ok {return nil}
	if app.error != .none {
		direct_async_stop(app)
		return nil
	}
	return app
}

direct_async_stop :: proc(app: ^DirectApp) {
	if app == nil {return}
	cs.base_server_shutdown(app)
	cs.base_server_wait(app, 5 * time.Second)
	if app.ctx != nil {
		free(app.ctx, app.alloc)
	}
	cs.base_router_destroy(app)
	free(app, app.alloc)
}
