package examples_async

import http "../../vendor/odin-http"
import "core:mem"
import "core:sync"
import "core:net"
import "core:thread"
import cs "../../http_cs"

Split_Work :: struct {
	body: string,
}

split_body_callback :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
	res := (^http.Response)(user_data)
	if err != nil {
		http.respond(res, http.body_error_status(err))
		return
	}

	work := new(Split_Work, context.temp_allocator)
	work.body = string(body)

	http.mark_async(res.async_handler, res, work)
	http.resume(res) // Immediate resume on same thread.
}

split_handler_proc :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		res.async_handler = h
		http.body(req, -1, res, split_body_callback)
		return
	}

	work := (^Split_Work)(res.async_state)
	defer { res.async_state = nil }

	if work.body == "ping" {
		http.respond_plain(res, "pong")
	} else {
		http.respond(res, http.Status.Unprocessable_Content)
	}
}

// --- Test Infrastructure ---

SplitApp :: struct {
	server:        http.Server,
	server_thread: ^thread.Thread,
	ready:         sync.Wait_Group,
	port:          int,
	alloc:         mem.Allocator,
}

split_serve_thread :: proc(t: ^thread.Thread) {
	app := (^SplitApp)(t.data)
	
	h := http.Handler{
		handle = split_handler_proc,
	}

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
	http.serve(&app.server, h)
}

split_async_start :: proc(port: int, alloc: mem.Allocator) -> ^SplitApp {
	app := new(SplitApp, alloc)
	app.alloc = alloc
	app.port = port
	sync.wait_group_add(&app.ready, 1)

	app.server_thread = thread.create(split_serve_thread)
	app.server_thread.data = app
	app.server_thread.init_context = context
	thread.start(app.server_thread)

	sync.wait(&app.ready)
	return app
}

split_async_stop :: proc(app: ^SplitApp) {
	if app == nil { return }
	http.server_shutdown(&app.server)
	thread.join(app.server_thread)
	thread.destroy(app.server_thread)
	free(app, app.alloc)
}
