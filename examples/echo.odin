// Echo example: single-worker pipeline that echoes the HTTP request body back.
//
// Architecture:
//   HTTP POST /echo → bridge → worker → bridge → HTTP 200 body
//
// The worker receives a Message and sends it back to msg.reply_to unchanged.
// This is the simplest possible pipeline: one stage, no translation.
//
// Usage from tests:
//   app := example_echo_start(8080, context.allocator)
//   // ... send requests ...
//   example_echo_stop(app)
package examples

import adapter "../handlers"
import cs "../http_cs"
import pl "../pipeline"
import mrt "../pipeline"
import matryoshka "../vendor/matryoshka"
import "core:mem"
import "core:thread"
import "core:time"

// EchoApp holds all resources for the echo example server.
EchoApp :: struct {
	using base:   cs.Base_Server,
	handler_data: adapter.Handler_Data,
	bridge:       adapter.Bridge,
	pipeline:     pl.EchoPipeline,
	stage_thread: ^thread.Thread,
}

// example_echo_start wires the echo pipeline and starts an HTTP server on the given port.
// Returns nil if any setup step fails; example_echo_stop is safe to call on nil.
// The server is ready to accept connections when this function returns.
example_echo_start :: proc(port: int, alloc: mem.Allocator) -> ^EchoApp {
	s: Maybe(^EchoApp)

	for {
		ptr := new(EchoApp, alloc)
		if ptr == nil {
			break
		}
		s = ptr

		if !cs.base_server_init(ptr, alloc) {
			break
		}
		ptr.endpoint.port = port

		// Build the single-worker echo pipeline.
		pipe, ok := pl.build_echo_pipeline(echo_worker, alloc)
		if !ok {
			ptr.error = .user_error
			break
		}
		ptr.pipeline = pipe

		// Spawn stage thread.
		ptr.stage_thread = mrt.spawn_stage(&ptr.pipeline.worker, alloc)
		if ptr.stage_thread == nil {
			ptr.error = .user_error
			break
		}

		// Wire bridge to worker inbox and register route.
		ptr.bridge = adapter.bridge_init(ptr.pipeline.worker.me.inbox, alloc)
		ptr.handler_data = adapter.Handler_Data {
			bridge = &ptr.bridge,
		}
		h := adapter.make_handler(&ptr.handler_data)

		if !cs.base_router_init(ptr) {
			break
		}
		if !cs.base_router_post(ptr, "/echo", h) {
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

	app, ok := s.(^EchoApp)
	if !ok {
		return nil
	}
	if app.error != .none {
		example_echo_stop(app)
		return nil
	}
	return app
}

// example_echo_stop shuts down the echo server and frees all resources.
// Safe to call on nil and on a partially-initialised app (error path from example_echo_start).
example_echo_stop :: proc(app: ^EchoApp) {
	if app == nil {
		return
	}

	// Server must be shut down before the pipeline closes.
	_, has_thread := app.server_thread.(^thread.Thread)
	if has_thread {
		cs.base_server_shutdown(app)
		cs.base_server_wait(app, 5 * time.Second)
	}

	// stage_thread non-nil implies the pipeline was successfully built.
	if app.stage_thread != nil {
		matryoshka.mbox_close(app.pipeline.worker.me.inbox)
		mrt.shutdown_threads([]^thread.Thread{app.stage_thread})
		pl.free_echo_pipeline(&app.pipeline)
	}

	cs.base_router_destroy(app)

	alloc := app.alloc
	free(app, alloc)
}

// echo_worker is the processing callback for the echo stage.
// It receives a Message and sends it back to msg.reply_to unchanged.
echo_worker :: proc(me: ^pl.Master, _: pl.Mailbox, mi: ^pl.MayItem) {
	pl.reply_to_bridge(me, mi)
}
