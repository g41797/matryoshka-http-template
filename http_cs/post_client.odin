// Simple http post client.
// Based on ../vendor/odin-http/examples/client/main

package http_cs

import http "../vendor/odin-http/"
import "../vendor/odin-http/client"
import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:thread"

//--------------------------------
// http://scooterlabs.com:80/echo:
// http				- scheme
// scooterlabs.com 	- host (or ip)
// 80				- port
// [/]echo			- path
//--------------------------------


// Uses http scheme and Plain mime-type.
Post_Client :: struct {
	alctr:       mem.Allocator,
	host_or_ip:  string,
	port:        int,
	path:        string,
	req_body:    [dynamic]u8,
	resp_body:   [dynamic]u8,
	status:      bool,
	http_status: Maybe(http.Status),
	post_thread: ^thread.Thread,
}

// ctor
new_Post_Client :: proc(alctr: mem.Allocator) -> ^Post_Client {
	pc, err := new(Post_Client, alctr)
	if err != .None {
		return nil
	}

	pc^.alctr = alctr
	pc^.req_body = make([dynamic]u8, 0, 0, pc^.alctr)
	pc^.resp_body = make([dynamic]u8, 0, 0, pc^.alctr)

	return pc
}

// dtor
free_Post_Client :: proc(pc: ^Post_Client) {
	if pc == nil {
		return
	}

	delete(pc^.req_body)
	delete(pc^.resp_body)

	if pc^.post_thread != nil {
		thread.join(pc^.post_thread)
		thread.destroy(pc^.post_thread)
		pc^.post_thread = nil
	}

	alctr := pc.alctr
	free(pc, alctr)

	return
}


// POST request.
// HTTP only.
// Plain mime type for every content.
// Successful if on return status == true and resp_body not empty.
// All in/out information is saved within struct.
post_req_resp :: proc(pc: ^Post_Client) {

	pc^.status = false
	pc^.http_status = nil
	clear(&pc^.resp_body)

	req: client.Request
	client.request_init(&req, .Post, pc^.alctr)
	defer client.request_destroy(&req)

	bytes.buffer_write_slice(&req.body, pc^.req_body[0:])

	http.headers_set_content_type(&req.headers, http.mime_to_content_type(.Plain))

	url := build_url(pc^.host_or_ip, pc^.port, pc^.path, pc^.alctr)

	defer delete(url, pc^.alctr)


	res, err := client.request(&req, url)
	if err != nil {
		fmt.printf("Request failed: %s", err)
		return
	}

	pc^.http_status = res.status

	defer client.response_destroy(&res)

	body, allocation, berr := client.response_body(&res)
	if berr != nil {
		fmt.printf("Error retrieving response body: %s", berr)
		return
	}
	defer client.body_destroy(body, allocation)

	switch b in body {
	case client.Body_Plain:
		append(&pc^.resp_body, b)
		pc^.status = true

	case client.Body_Url_Encoded:

	case client.Body_Error:

	}

	return
}

// creates and starts thread for one post operation.
// may be called several times:
// 		run_on_thread(...)
// 		................
// 		wait_thread(...)

run_on_thread :: proc(pc: ^Post_Client) -> bool {

	pc^.post_thread = thread.create(post_client_thread)
	if pc^.post_thread == nil {
		fmt.println("Creation of post thread failed")
		return false
	}

	pc^.post_thread^.data = pc
	pc^.post_thread^.init_context = context
	thread.start(pc^.post_thread)

	return true
}

// wait finish of post on the thread.
wait_thread :: proc(pc: ^Post_Client) -> bool {

	if pc^.post_thread == nil {
		return false
	}

	thread.join(pc^.post_thread)
	thread.destroy(pc^.post_thread)
	pc^.post_thread = nil

	return true
}

// Thread container for single POST HTTP request/response.
post_client_thread :: proc(t: ^thread.Thread) {
	pc := (^Post_Client)(t.data)
	post_req_resp(pc)
}
