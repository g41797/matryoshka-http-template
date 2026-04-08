// Full pipeline example: translator_in → worker → translator_out.
//
// Architecture:
//   HTTP POST /pipeline → bridge → translator_in → worker → translator_out → bridge → HTTP 200
//
// translator_in: receives Message from bridge, passes it to the worker mailbox.
// worker:        receives Message, processes payload (uppercases body), forwards to translator_out.
// translator_out: receives processed Message, sends it back to reply_to (the bridge).
//
// This example demonstrates the unified Master model: all three stages use the same
// Master struct and stage_proc — only the Stage_Fn callback changes.
//
// Usage from tests:
//   app, ok := example_pipeline_start(8081, context.allocator)
//   // ... send requests ...
//   example_pipeline_stop(app)
package examples

import http "../vendor/odin-http"
import adapter "../adapter/http"
import pl "../pipeline"
import mrt "../spawn"
import matryoshka "../vendor/matryoshka"
import "core:mem"
import "core:net"
import "core:sync"
import "core:thread"

// Pipeline_Serve_Ctx is passed to the background server thread.
@(private)
Pipeline_Serve_Ctx :: struct {
	server:   ^http.Server,
	handler:  http.Handler,
	endpoint: net.Endpoint,
	opts:     http.Server_Opts,
	ready:    sync.Wait_Group,
	ok:       bool,
}

// PipelineApp holds all resources for the full-pipeline example server.
PipelineApp :: struct {
	server:        http.Server,
	server_thread: ^thread.Thread,
	serve_ctx:     ^Pipeline_Serve_Ctx,
	router:        http.Router,
	handler_data:  adapter.Handler_Data,
	bridge:        adapter.Bridge,
	pipeline:      pl.FullPipeline,
	stage_threads: [3]^thread.Thread,
	alloc:         mem.Allocator,
}

@(private)
pipeline_serve_thread :: proc(t: ^thread.Thread) {
	ctx := (^Pipeline_Serve_Ctx)(t.data)
	err := http.listen(ctx.server, ctx.endpoint, ctx.opts)
	ctx.ok = err == nil
	sync.wait_group_done(&ctx.ready)
	if ctx.ok {
		http.serve(ctx.server, ctx.handler)
	}
}

// example_pipeline_start wires the three-stage pipeline and starts an HTTP server.
// Returns nil if setup fails.
example_pipeline_start :: proc(port: int, alloc: mem.Allocator) -> ^PipelineApp {
	app := new(PipelineApp, alloc)
	if app == nil {
		return nil
	}
	app.alloc = alloc

	// Build the three-stage pipeline.
	pipe, ok := pl.build_full_pipeline(pipeline_translate_in, pipeline_worker, pipeline_translate_out, alloc)
	if !ok {
		free(app, alloc)
		return nil
	}
	app.pipeline = pipe

	// Spawn one thread per stage.
	app.stage_threads[0] = mrt.spawn_stage(&app.pipeline.translator_in, alloc)
	app.stage_threads[1] = mrt.spawn_stage(&app.pipeline.worker, alloc)
	app.stage_threads[2] = mrt.spawn_stage(&app.pipeline.translator_out, alloc)
	for t in app.stage_threads {
		if t == nil {
			// Shutdown already-started threads and pipeline.
			matryoshka.mbox_close(app.pipeline.translator_in.me.inbox)
			matryoshka.mbox_close(app.pipeline.worker.me.inbox)
			matryoshka.mbox_close(app.pipeline.translator_out.me.inbox)
			mrt.shutdown_threads(app.stage_threads[:])
			pl.free_full_pipeline(&app.pipeline)
			free(app, alloc)
			return nil
		}
	}

	// Wire bridge to translator_in inbox (entry point of the pipeline).
	app.bridge = adapter.bridge_init(app.pipeline.translator_in.me.inbox, alloc)
	app.handler_data = adapter.Handler_Data{bridge = &app.bridge}

	// Set up HTTP router.
	http.router_init(&app.router)
	h := adapter.make_handler(&app.handler_data)
	http.route_post(&app.router, "/pipeline", h)
	route_handler := http.router_handler(&app.router)

	// Allocate serve context.
	serve_ctx := new(Pipeline_Serve_Ctx, alloc)
	if serve_ctx == nil {
		matryoshka.mbox_close(app.pipeline.translator_in.me.inbox)
		matryoshka.mbox_close(app.pipeline.worker.me.inbox)
		matryoshka.mbox_close(app.pipeline.translator_out.me.inbox)
		mrt.shutdown_threads(app.stage_threads[:])
		pl.free_full_pipeline(&app.pipeline)
		http.router_destroy(&app.router)
		free(app, alloc)
		return nil
	}
	serve_ctx.server   = &app.server
	serve_ctx.handler  = route_handler
	serve_ctx.endpoint = net.Endpoint{address = net.IP4_Loopback, port = port}
	serve_ctx.opts     = http.Server_Opts{
		auto_expect_continue = true,
		redirect_head_to_get = true,
		limit_request_line   = 8000,
		limit_headers        = 8000,
		thread_count         = 1,
	}
	sync.wait_group_add(&serve_ctx.ready, 1)
	app.serve_ctx = serve_ctx

	// Start server thread (listen + serve run together on the same thread).
	app.server_thread = thread.create(pipeline_serve_thread)
	if app.server_thread == nil {
		free(serve_ctx, alloc)
		matryoshka.mbox_close(app.pipeline.translator_in.me.inbox)
		matryoshka.mbox_close(app.pipeline.worker.me.inbox)
		matryoshka.mbox_close(app.pipeline.translator_out.me.inbox)
		mrt.shutdown_threads(app.stage_threads[:])
		pl.free_full_pipeline(&app.pipeline)
		http.router_destroy(&app.router)
		free(app, alloc)
		return nil
	}
	app.server_thread.data         = serve_ctx
	app.server_thread.init_context = context
	thread.start(app.server_thread)

	// Block until listen has completed.
	sync.wait(&serve_ctx.ready)
	if !serve_ctx.ok {
		thread.join(app.server_thread)
		thread.destroy(app.server_thread)
		free(serve_ctx, alloc)
		matryoshka.mbox_close(app.pipeline.translator_in.me.inbox)
		matryoshka.mbox_close(app.pipeline.worker.me.inbox)
		matryoshka.mbox_close(app.pipeline.translator_out.me.inbox)
		mrt.shutdown_threads(app.stage_threads[:])
		pl.free_full_pipeline(&app.pipeline)
		http.router_destroy(&app.router)
		free(app, alloc)
		return nil
	}

	return app
}

// example_pipeline_stop shuts down the server and frees all resources.
example_pipeline_stop :: proc(app: ^PipelineApp) {
	if app == nil {
		return
	}

	http.server_shutdown(&app.server)
	thread.join(app.server_thread)
	thread.destroy(app.server_thread)
	free(app.serve_ctx, app.alloc)

	// Close stages in order: translator_in first, then worker, then translator_out.
	// Each close causes the stage thread to exit its receive loop.
	matryoshka.mbox_close(app.pipeline.translator_in.me.inbox)
	matryoshka.mbox_close(app.pipeline.worker.me.inbox)
	matryoshka.mbox_close(app.pipeline.translator_out.me.inbox)
	mrt.shutdown_threads(app.stage_threads[:])

	pl.free_full_pipeline(&app.pipeline)
	http.router_destroy(&app.router)

	alloc := app.alloc
	free(app, alloc)
}

// pipeline_translate_in forwards the Message to the worker mailbox without modification.
// In a real application, this stage would convert from HTTP-domain types to domain types.
pipeline_translate_in :: proc(me: ^pl.Master, next: pl.Mailbox, mi: ^pl.MayItem) {
	pl.forward_to_next(me, next, mi)
}

// pipeline_worker uppercases the payload, demonstrating domain processing.
// In a real application, this stage contains the business logic.
pipeline_worker :: proc(me: ^pl.Master, next: pl.Mailbox, mi: ^pl.MayItem) {
	ptr, ok := mi^.?
	if !ok {
		return
	}
	msg := (^pl.Message)(ptr)

	// Uppercase the payload in place (ASCII fast path).
	for i in 0 ..< len(msg.payload) {
		b := msg.payload[i]
		if b >= 'a' && b <= 'z' {
			msg.payload[i] = b - 32
		}
	}

	pl.forward_to_next(me, next, mi)
}

// pipeline_translate_out sends the processed Message back to the bridge via reply_to.
// In a real application, this stage would convert from domain types to HTTP-domain types.
pipeline_translate_out :: proc(me: ^pl.Master, _: pl.Mailbox, mi: ^pl.MayItem) {
	pl.reply_to_bridge(me, mi)
}
