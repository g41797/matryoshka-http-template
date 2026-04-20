package examples_async

import http "../../vendor/odin-http"
import "core:thread"
import "core:mem"
import "core:sync"
import "core:net"
import "core:time"
import cs "../../http_cs"

Body_Context :: struct {
	alloc: mem.Allocator,
}

Body_Work :: struct {
	alloc:  mem.Allocator,
	thread: ^thread.Thread,
	body:   string,
	result: string,
}

body_background_proc :: proc(t: ^thread.Thread) {
	res := (^http.Response)(t.data)
	work := (^Body_Work)(res.async_state)

	// Simulate work using the body.
	time.sleep(10 * time.Millisecond)
	work.result = work.body

	http.resume(res)
}

body_callback :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
	res := (^http.Response)(user_data)
	ctx := (^Body_Context)(res._conn.server.handler.user_data)

	if err != nil {
		http.respond(res, http.body_error_status(err))
		return
	}

	work := new(Body_Work, ctx.alloc)
	work.alloc = ctx.alloc
	work.body = string(body)

	// mark_async uses the handler stored earlier.
	http.mark_async(res.async_handler, res, work)

	t := thread.create(body_background_proc)
	if t == nil {
		http.cancel_async(res)
		free(work, ctx.alloc)
		http.respond(res, http.Status.Internal_Server_Error)
		return
	}
	t.data = res
	work.thread = t
	thread.start(t)
}

body_handler_proc :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		// Store handler for later use in callback.
		res.async_handler = h
		http.body(req, -1, res, body_callback)
		return
	}

	work := (^Body_Work)(res.async_state)
	defer {
		thread.join(work.thread)
		thread.destroy(work.thread)
		free(work, work.alloc)
		res.async_state = nil
	}

	http.respond_plain(res, work.result)
}

// --- Test Infrastructure ---

BodyApp :: struct {
	server:        http.Server,
	server_thread: ^thread.Thread,
	ready:         sync.Wait_Group,
	port:          int,
	alloc:         mem.Allocator,
	ctx:           ^Body_Context,
}

body_serve_thread :: proc(t: ^thread.Thread) {
	app := (^BodyApp)(t.data)
	
	router: http.Router
	http.router_init(&router, app.alloc)
	defer http.router_destroy(&router)

	h := http.Handler{
		handle = body_handler_proc,
		user_data = app.ctx,
	}
	http.route_post(&router, "/body", h)

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

	app.port, _ = cs.get_listening_port(&app.server)

	sync.wait_group_done(&app.ready)
	http.serve(&app.server, http.router_handler(&router))
}

body_async_start :: proc(port: int, alloc: mem.Allocator) -> ^BodyApp {
	app := new(BodyApp, alloc)
	app.alloc = alloc
	app.port = port
	app.ctx = new(Body_Context, alloc)
	app.ctx.alloc = alloc
	sync.wait_group_add(&app.ready, 1)

	app.server_thread = thread.create(body_serve_thread)
	app.server_thread.data = app
	app.server_thread.init_context = context
	thread.start(app.server_thread)

	sync.wait(&app.ready)
	return app
}

body_async_stop :: proc(app: ^BodyApp) {
	if app == nil { return }
	http.server_shutdown(&app.server)
	thread.join(app.server_thread)
	thread.destroy(app.server_thread)
	free(app.ctx, app.alloc)
	free(app, app.alloc)
}
