package http_cs

import http "http:."
import "http:client"
import "core:bytes"
import "core:mem"
import "core:thread"

// Error at the http_cs level — separate from network errors in client.Error.
Post_Client_Error :: enum {
	None,
	Thread_Spawn_Failed,
	Invalid_Index,
}

// Internal unit representing a single HTTP POST lifecycle.
Post_Client_Unit :: struct {
	url:        string,
	body:       []u8,
	mime:       http.Mime_Type,
	req:        client.Request,
	res:        client.Response,
	client_err: client.Error,
	resp_body:  [dynamic]u8,
	success:    bool,
	post_err:   Post_Client_Error,
	thread:     ^thread.Thread,
}

// Public orchestrator for a batch of POST requests.
Post_Clients :: struct {
	alloc: mem.Allocator,
	units: []Post_Client_Unit,
}

// Initialize the orchestrator for a specific number of clients.
post_clients_init :: proc(clients: ^Post_Clients, count: int, alloc: mem.Allocator) -> bool {
	clients.alloc = alloc
	clients.units = make([]Post_Client_Unit, count, alloc)
	if clients.units == nil {
		return false
	}

	for i in 0 ..< count {
		clients.units[i].resp_body = make([dynamic]u8, 0, 256, alloc)
	}

	return true
}

// Join threads and free all internal resources.
post_clients_destroy :: proc(clients: ^Post_Clients) {
	if clients == nil || clients.units == nil {
		return
	}

	for i in 0 ..< len(clients.units) {
		u := &clients.units[i]
		if u.thread != nil {
			thread.join(u.thread)
			thread.destroy(u.thread)
		}
		client.response_destroy(&u.res)
		client.request_destroy(&u.req)
		delete(u.resp_body)
	}

	delete(clients.units, clients.alloc)
}

// Configure a task for a specific client in the batch.
post_clients_set_task :: proc(clients: ^Post_Clients, index: int, url: string, body: []u8, mime := http.Mime_Type.Plain) {
	if index >= len(clients.units) {
		return
	}
	u := &clients.units[index]
	u.url = url
	u.body = body
	u.mime = mime
}

// Internal thread proc: performs only the blocking I/O.
@(private)
post_client_io_proc :: proc(t: ^thread.Thread) {
	u := (^Post_Client_Unit)(t.data)
	u.res, u.client_err = client.request(&u.req, u.url, context.allocator)
}

// Single-use: call once per init. Re-run needs post_clients_destroy + post_clients_init.
post_clients_run :: proc(clients: ^Post_Clients) {
	// 1. Prepare requests on main thread
	for i in 0 ..< len(clients.units) {
		u := &clients.units[i]
		client.request_init(&u.req, .Post, clients.alloc)
		http.headers_set_content_type(&u.req.headers, http.mime_to_content_type(u.mime))
		if len(u.body) > 0 {
			bytes.buffer_write_slice(&u.req.body, u.body)
		}
	}

	// 2. Spawn threads
	for i in 0 ..< len(clients.units) {
		u := &clients.units[i]
		u.thread = thread.create(post_client_io_proc)
		if u.thread != nil {
			u.thread.data = u
			u.thread.init_context = context
			thread.start(u.thread)
		} else {
			u.post_err = .Thread_Spawn_Failed
		}
	}

	// 3. Join & Analyze
	for i in 0 ..< len(clients.units) {
		u := &clients.units[i]
		if u.thread != nil {
			thread.join(u.thread)
			thread.destroy(u.thread)
			u.thread = nil
		}

		if u.client_err == nil {
			body, was_alloc, berr := client.response_body(&u.res)
			if berr == nil {
				if b_plain, ok := body.(client.Body_Plain); ok {
					if len(b_plain) > 0 {
						append(&u.resp_body, ..transmute([]u8)b_plain)
					}
					u.success = (u.res.status == .OK)
				}
				client.body_destroy(body, was_alloc)
			}
		}
	}
}

// Check if a specific task was successful.
post_clients_was_successful :: proc(clients: ^Post_Clients, index: int) -> bool {
	if index >= len(clients.units) {
		return false
	}
	return clients.units[index].success
}

// Retrieve results for a specific task.
post_clients_get_result :: proc(clients: ^Post_Clients, index: int) -> (status: http.Status, body: []u8, net_err: client.Error, err: Post_Client_Error) {
	if index >= len(clients.units) {
		return http.Status(0), nil, nil, .Invalid_Index
	}
	u := &clients.units[index]
	return u.res.status, u.resp_body[:], u.client_err, u.post_err
}
