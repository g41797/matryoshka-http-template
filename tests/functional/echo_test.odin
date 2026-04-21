//+test
// Functional test: starts the echo HTTP server, sends a POST request, asserts the response.
// Uses the odin-http client — the same library the server is built on.
package test_functional

import ex "../../examples"
import client "../../vendor/odin-http/client"
import cs "../../http_cs"
import "core:bytes"
import "core:testing"

@(test)
test_echo_http_round_trip :: proc(t: ^testing.T) {
	app := ex.example_echo_start(0, context.allocator)
	if !testing.expect(t, app != nil, "example_echo_start should succeed") {
		return
	}
	defer ex.example_echo_stop(app)

	if !testing.expect(t, app^.port != nil, "example_echo_start should bind an ephemeral port") {
		return
	}

	req: client.Request
	client.request_init(&req, .Post)
	defer client.request_destroy(&req)
	bytes.buffer_write_string(&req.body, "hello")

	url := cs.build_url("127.0.0.1", app^.port.(int), "/echo", context.temp_allocator)
	res, err := client.request(&req, url)
	if !testing.expect(t, err == nil, "HTTP request should succeed") {
		return
	}
	defer client.response_destroy(&res)

	body, was_allocation, body_err := client.response_body(&res)
	if !testing.expect(t, body_err == nil, "response body should be readable") {
		return
	}
	defer client.body_destroy(body, was_allocation)

	body_str, ok := body.(client.Body_Plain)
	testing.expect(t, ok, "response should be plain text")
	testing.expect(t, body_str == "hello", "echo response should match request body")
}

@(test)
test_echo_empty_body :: proc(t: ^testing.T) {
	app := ex.example_echo_start(0, context.allocator)
	if !testing.expect(t, app != nil, "example_echo_start should succeed") {
		return
	}
	defer ex.example_echo_stop(app)

	if !testing.expect(t, app^.port != nil, "example_echo_start should bind an ephemeral port") {
		return
	}

	req: client.Request
	client.request_init(&req, .Post)
	defer client.request_destroy(&req)
	// Empty body: nothing written to req.body.

	url := cs.build_url("127.0.0.1", app^.port.(int), "/echo", context.temp_allocator)
	res, err := client.request(&req, url)
	if !testing.expect(t, err == nil, "HTTP request should succeed") {
		return
	}
	defer client.response_destroy(&res)

	body, was_allocation, body_err := client.response_body(&res)
	if !testing.expect(t, body_err == nil, "response body should be readable") {
		return
	}
	defer client.body_destroy(body, was_allocation)

	body_str, ok := body.(client.Body_Plain)
	testing.expect(t, ok, "response should be plain text")
	testing.expect(t, body_str == "", "echo response should be empty for empty body")
}
