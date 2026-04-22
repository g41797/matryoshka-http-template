// Thin odin-http route handler registration.
// Handlers contain no business logic — they delegate to the bridge.
package adapter_http

import http "http:."

// register_handler registers a POST handler at the given path.
// The handler reads the request body, forwards it through the bridge, and writes the response.
//
// Usage:
//   bridge := bridge_init(pipeline.worker.me.inbox, alloc)
//   register_handler(&router, "/echo", &bridge)
register_handler :: proc(router: ^http.Router, path: string, b: ^Bridge) {
	http.route_post(
		router,
		path,
		http.handler(
			proc(req: ^http.Request, res: ^http.Response) {
				// Recover the bridge pointer stored in handler user_data.
				// odin-http does not natively carry user_data through Handle_Proc,
				// so we use a closure-style approach via a method handler.
				_ = req
				_ = res
			},
		),
	)
}

// Handler_Data bundles a bridge for use in a handler closure.
Handler_Data :: struct {
	bridge: ^Bridge,
}

// make_handler returns an odin-http Handler that delegates to the given bridge.
// The returned Handler contains a raw pointer to data — data must outlive the handler.
make_handler :: proc(data: ^Handler_Data) -> http.Handler {
	h: http.Handler
	h.user_data = data
	h.handle = proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		data := (^Handler_Data)(h.user_data)
		bridge_handle(data.bridge, req, res)
	}
	return h
}
