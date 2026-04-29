//+test
package test_async

import cs "../../../http_cs"
import "core:mem"
import "core:testing"
import "core:time"
import http "http:."
import ex "http:examples/async"

@(test)
test_body_async :: proc(t: ^testing.T) {
	app := body_async_start(0, context.allocator)
	if !testing.expect(t, app != nil, "body_async_start failed") {
		return
	}
	defer body_async_stop(app)

	url := cs.build_url("127.0.0.1", app.port.(int), "/body", context.temp_allocator)

	N :: 3
	clients: cs.Post_Clients
	cs.post_clients_init(&clients, N, context.allocator)
	defer cs.post_clients_destroy(&clients)

	for i in 0 ..< N {
		cs.post_clients_set_task(&clients, i, url, transmute([]u8)string("async echo"))
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
		testing.expectf(t, string(body) == "async echo", "request %d response should match", i)
	}
}


// --- Test Infrastructure ---

BodyApp :: struct {
	using base: cs.Base_Server,
	ctx:        ^ex.Body_Context,
}

body_async_start :: proc(port: int, alloc: mem.Allocator) -> ^BodyApp {
	s: Maybe(^BodyApp)

	for {
		ptr := new(BodyApp, alloc)
		if ptr == nil {
			break
		}
		s = ptr

		if !cs.base_server_init(ptr, alloc) {
			break
		}
		ptr.endpoint.port = port

		ctx := new(ex.Body_Context, alloc)
		if ctx == nil {
			ptr.error = .user_error
			break
		}
		ctx.alloc = alloc
		ptr.ctx = ctx

		h := http.Handler {
			handle    = ex.body_handler,
			user_data = ptr.ctx,
		}

		if !cs.base_router_init(ptr) {
			break
		}
		if !cs.base_router_post(ptr, "/body", h) {
			break
		}
		if !cs.base_router_handler(ptr) {
			break
		}
		if !cs.base_server_start(ptr) {
			break
		}

		break
	}

	app, ok := s.(^BodyApp)
	if !ok {
		return nil
	}
	if app.error != .none {
		body_async_stop(app)
		return nil
	}
	return app
}

body_async_stop :: proc(app: ^BodyApp) {
	if app == nil {
		return
	}
	cs.base_server_shutdown(app)
	cs.base_server_wait(app, 5 * time.Second)
	if app.ctx != nil {
		free(app.ctx, app.alloc)
	}
	cs.base_router_destroy(app)
	free(app, app.alloc)
}
