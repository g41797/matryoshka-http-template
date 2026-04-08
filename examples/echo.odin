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

import http "../vendor/odin-http"
import adapter "../adapter/http"
import pl "../pipeline"
import mrt "../spawn"
import matryoshka "../vendor/matryoshka"
import "core:mem"
import "core:net"
import "core:sync"
import "core:thread"

// Serve_Ctx is passed to the background server thread.
// It holds everything needed to call http.listen + http.serve,
// plus a wait group so example_echo_start can block until listen completes.
@(private)
Echo_Serve_Ctx :: struct {
	server:   ^http.Server,
	handler:  http.Handler,
	endpoint: net.Endpoint,
	opts:     http.Server_Opts,
	// Signalled (done) after http.listen returns, whether ok or not.
	ready:    sync.Wait_Group,
	// True if http.listen succeeded.
	ok:       bool,
}

// EchoApp holds all resources for the echo example server.
EchoApp :: struct {
	server:        http.Server,
	server_thread: ^thread.Thread,
	serve_ctx:     ^Echo_Serve_Ctx,
	router:        http.Router,
	handler_data:  adapter.Handler_Data,
	bridge:        adapter.Bridge,
	pipeline:      pl.EchoPipeline,
	stage_thread:  ^thread.Thread,
	alloc:         mem.Allocator,
}

// echo_serve_thread is the proc that runs in the server background thread.
// It calls http.listen (acquiring the nbio event loop on this thread),
// signals ready, then calls http.serve (which blocks until shutdown).
@(private)
echo_serve_thread :: proc(t: ^thread.Thread) {
	ctx := (^Echo_Serve_Ctx)(t.data)
	err := http.listen(ctx.server, ctx.endpoint, ctx.opts)
	ctx.ok = err == nil
	sync.wait_group_done(&ctx.ready)
	if ctx.ok {
		http.serve(ctx.server, ctx.handler)
	}
}

// example_echo_start wires the echo pipeline and starts an HTTP server on the given port.
// Returns nil if setup fails.
// The server is ready to accept connections when this function returns.
example_echo_start :: proc(port: int, alloc: mem.Allocator) -> ^EchoApp {
	app := new(EchoApp, alloc)
	if app == nil {
		return nil
	}
	app.alloc = alloc

	// Build the single-worker echo pipeline.
	pipe, ok := pl.build_echo_pipeline(echo_worker, alloc)
	if !ok {
		free(app, alloc)
		return nil
	}
	app.pipeline = pipe

	// Spawn stage thread.
	app.stage_thread = mrt.spawn_stage(&app.pipeline.worker, alloc)
	if app.stage_thread == nil {
		pl.free_echo_pipeline(&app.pipeline)
		free(app, alloc)
		return nil
	}

	// Wire bridge to worker inbox.
	app.bridge = adapter.bridge_init(app.pipeline.worker.me.inbox, alloc)
	app.handler_data = adapter.Handler_Data{bridge = &app.bridge}

	// Set up HTTP router.
	http.router_init(&app.router)
	h := adapter.make_handler(&app.handler_data)
	http.route_post(&app.router, "/echo", h)
	route_handler := http.router_handler(&app.router)

	// Allocate serve context (lives until after server thread joins).
	serve_ctx := new(Echo_Serve_Ctx, alloc)
	if serve_ctx == nil {
		matryoshka.mbox_close(app.pipeline.worker.me.inbox)
		mrt.shutdown_threads([]^thread.Thread{app.stage_thread})
		pl.free_echo_pipeline(&app.pipeline)
		http.router_destroy(&app.router)
		free(app, alloc)
		return nil
	}
	serve_ctx.server   = &app.server
	serve_ctx.handler  = route_handler
	serve_ctx.endpoint = net.Endpoint{address = net.IP4_Loopback, port = port}
	// Use thread_count=1 to avoid io_uring resource limits during parallel test runs.
	// Production servers omit this to use all CPU cores.
	serve_ctx.opts     = http.Server_Opts{
		auto_expect_continue = true,
		redirect_head_to_get = true,
		limit_request_line   = 8000,
		limit_headers        = 8000,
		thread_count         = 1,
	}
	sync.wait_group_add(&serve_ctx.ready, 1)
	app.serve_ctx = serve_ctx

	// Start the server thread. listen + serve both run there so they share the same nbio event loop.
	app.server_thread = thread.create(echo_serve_thread)
	if app.server_thread == nil {
		free(serve_ctx, alloc)
		matryoshka.mbox_close(app.pipeline.worker.me.inbox)
		mrt.shutdown_threads([]^thread.Thread{app.stage_thread})
		pl.free_echo_pipeline(&app.pipeline)
		http.router_destroy(&app.router)
		free(app, alloc)
		return nil
	}
	app.server_thread.data         = serve_ctx
	app.server_thread.init_context = context
	thread.start(app.server_thread)

	// Block until http.listen has been called (socket is bound and accepting).
	sync.wait(&serve_ctx.ready)
	if !serve_ctx.ok {
		// listen failed; the server thread has already exited.
		thread.join(app.server_thread)
		thread.destroy(app.server_thread)
		free(serve_ctx, alloc)
		matryoshka.mbox_close(app.pipeline.worker.me.inbox)
		mrt.shutdown_threads([]^thread.Thread{app.stage_thread})
		pl.free_echo_pipeline(&app.pipeline)
		http.router_destroy(&app.router)
		free(app, alloc)
		return nil
	}

	return app
}

// example_echo_stop shuts down the echo server and frees all resources.
example_echo_stop :: proc(app: ^EchoApp) {
	if app == nil {
		return
	}

	// Signal the HTTP server to stop accepting and close all connections.
	// serve() will return after all connections drain.
	http.server_shutdown(&app.server)
	thread.join(app.server_thread)
	thread.destroy(app.server_thread)
	// serve_ctx is safe to free now that the server thread has joined.
	free(app.serve_ctx, app.alloc)

	// Close pipeline stage and wait for its thread.
	matryoshka.mbox_close(app.pipeline.worker.me.inbox)
	mrt.shutdown_threads([]^thread.Thread{app.stage_thread})

	// Free pipeline resources.
	pl.free_echo_pipeline(&app.pipeline)

	// Destroy router.
	http.router_destroy(&app.router)

	alloc := app.alloc
	free(app, alloc)
}

// echo_worker is the processing callback for the echo stage.
// It receives a Message and sends it back to msg.reply_to unchanged.
echo_worker :: proc(me: ^pl.Master, _: pl.Mailbox, mi: ^pl.MayItem) {
	pl.reply_to_bridge(me, mi)
}
