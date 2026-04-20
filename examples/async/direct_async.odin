package examples_async

import http "../../vendor/odin-http"
import "core:thread"
import "core:mem"
import "core:sync"
import "core:net"
import "core:time"
import cs "../../http_cs"

// Context shared by handlers, set at route registration.
Direct_Context :: struct {
	alloc: mem.Allocator,
}

// Work allocated for each request.
Direct_Work :: struct {
	alloc:  mem.Allocator,
	thread: ^thread.Thread,
	result: string,
}

// Background work procedure.
direct_background_proc :: proc(t: ^thread.Thread) {
	res := (^http.Response)(t.data)
	work := (^Direct_Work)(res.async_state)

	// Simulate some slow work.
	time.sleep(10 * time.Millisecond)
	work.result = "hello from background"

	// Signal the io thread.
	http.resume(res)
}

// Handler procedure.
direct_handler_proc :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	ctx := (^Direct_Context)(h.user_data)

	if res.async_state == nil {
		// Part 1: First call.
		work := new(Direct_Work, ctx.alloc)
		work.alloc = ctx.alloc

		// Preparation -> mark_async -> start work.
		http.mark_async(h, res, work)

		t := thread.create(direct_background_proc)
		if t == nil {
			// Roll back if thread creation fails.
			http.cancel_async(res)
			free(work, ctx.alloc)
			http.respond(res, http.Status.Internal_Server_Error)
			return
		}
		t.data = res
		work.thread = t
		thread.start(t)
		return
	}

	// Part 2: Resume call.
	work := (^Direct_Work)(res.async_state)
	defer {
		thread.join(work.thread)
		thread.destroy(work.thread)
		free(work, work.alloc)
		res.async_state = nil // Important for cleanup.
	}

	http.respond_plain(res, work.result)
}

// --- Test Infrastructure ---

DirectApp :: struct {
	server:        http.Server,
	server_thread: ^thread.Thread,
	ready:         sync.Wait_Group,
	port:          int,
	alloc:         mem.Allocator,
	ctx:           ^Direct_Context,
}

direct_serve_thread :: proc(t: ^thread.Thread) {
	app := (^DirectApp)(t.data)
	
	router: http.Router
	http.router_init(&router, app.alloc)
	defer http.router_destroy(&router)

	h := http.Handler{
		handle = direct_handler_proc,
		user_data = app.ctx,
	}
	http.route_get(&router, "/direct", h)

	endpoint := net.Endpoint{
		address = net.IP4_Loopback,
		port = app.port,
	}

	opts := http.Default_Server_Opts
	opts.thread_count = 1

	err := http.listen(&app.server, endpoint, opts)
	if err != nil {
		sync.wait_group_done(&app.ready)
		return
	}

	// Update with actual ephemeral port if 0 was used.
	app.port, _ = cs.get_listening_port(&app.server)

	sync.wait_group_done(&app.ready)
	http.serve(&app.server, http.router_handler(&router))
}

direct_async_start :: proc(port: int, alloc: mem.Allocator) -> ^DirectApp {
	app := new(DirectApp, alloc)
	app.alloc = alloc
	app.port = port
	app.ctx = new(Direct_Context, alloc)
	app.ctx.alloc = alloc
	sync.wait_group_add(&app.ready, 1)

	app.server_thread = thread.create(direct_serve_thread)
	app.server_thread.data = app
	app.server_thread.init_context = context
	thread.start(app.server_thread)

	sync.wait(&app.ready)
	return app
}

direct_async_stop :: proc(app: ^DirectApp) {
	if app == nil { return }
	http.server_shutdown(&app.server)
	thread.join(app.server_thread)
	thread.destroy(app.server_thread)
	free(app.ctx, app.alloc)
	free(app, app.alloc)
}
