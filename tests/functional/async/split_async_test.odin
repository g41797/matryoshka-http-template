//+test
// Smoke test for the async machinery.
// Uses the "Split Handler" pattern: mark_async + resume called from the same thread.
package test_async

import http "../../../vendor/odin-http"
import client "../../../vendor/odin-http/client"
import "core:bytes"
import "core:testing"
import "core:time"
import "core:sync"
import "core:thread"
import "core:net"

Split_Work :: struct {
	body: string,
}

// Fires after the body is read.
// We go async and immediately resume on the same thread.
split_body_callback :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
	res := (^http.Response)(user_data)
	if err != nil {
		http.respond(res, http.body_error_status(err))
		return
	}

	// Use the connection arena (temp_allocator).
	// Safe because we are on the io thread and async_state is set.
	work := new(Split_Work, context.temp_allocator)
	work.body = string(body)

	http.mark_async(res.async_handler, res, work)
	http.resume(res)
}

split_ping_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		// Part 1: start reading the body
		res.async_handler = h
		http.body(req, -1, res, split_body_callback)
		return
	}

	// Part 2: resume call
	work := (^Split_Work)(res.async_state)
	defer { res.async_state = nil }

	if work.body == "ping" {
		http.respond_plain(res, "pong")
	} else {
		http.respond(res, http.Status.Unprocessable_Content)
	}
}

Split_Serve_Ctx :: struct {
	server:  ^http.Server,
	ready:   sync.Wait_Group,
	port:    int,
}

split_serve_thread :: proc(t: ^thread.Thread) {
	ctx := (^Split_Serve_Ctx)(t.data)
	
	h := http.Handler{
		handle = split_ping_handler,
	}

	endpoint := net.Endpoint{
		address = net.IP4_Loopback,
		port = ctx.port,
	}

	opts := http.Default_Server_Opts
	opts.thread_count = 1

	err := http.listen(ctx.server, endpoint, opts)
	if err != nil {
		sync.wait_group_done(&ctx.ready)
		return
	}

	sync.wait_group_done(&ctx.ready)
	http.serve(ctx.server, h)
}

@(test)
test_split_async_smoke :: proc(t: ^testing.T) {
	port := 18082
	server: http.Server
	
	ctx: Split_Serve_Ctx
	ctx.server = &server
	ctx.port = port
	sync.wait_group_add(&ctx.ready, 1)

	th := thread.create(split_serve_thread)
	th.data = &ctx
	th.init_context = context
	thread.start(th)

	sync.wait(&ctx.ready)
	time.sleep(50 * time.Millisecond)

	req: client.Request
	client.request_init(&req, .Post)
	defer client.request_destroy(&req)
	
	bytes.buffer_write_string(&req.body, "ping")

	url := "http://127.0.0.1:18082/"
	res, err := client.request(&req, url)
	if !testing.expect(t, err == nil, "HTTP request should succeed") {
		http.server_shutdown(&server)
		thread.join(th)
		return
	}
	defer client.response_destroy(&res)

	testing.expect(t, res.status == .OK, "status should be 200 OK")

	body, was_alloc, body_err := client.response_body(&res)
	testing.expect(t, body_err == nil, "body should be readable")
	defer client.body_destroy(body, was_alloc)

	body_str, ok := body.(client.Body_Plain)
	testing.expect(t, ok, "body should be plain text")
	testing.expect(t, body_str == "pong", "response should be pong")

	http.server_shutdown(&server)
	thread.join(th)
	thread.destroy(th)
}
