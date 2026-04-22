//+test
// Functional test: starts the echo HTTP server, sends a POST request, asserts the response.
// Uses the Post_Clients batch orchestrator for network interaction.
package test_functional

import ex "../../examples"
import cs "../../http_cs"
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

	url := cs.build_url("127.0.0.1", app^.port.(int), "/echo", context.temp_allocator)

	clients: cs.Post_Clients
	cs.post_clients_init(&clients, 1, context.allocator)
	defer cs.post_clients_destroy(&clients)

	cs.post_clients_set_task(&clients, 0, url, transmute([]u8)string("hello"))
	cs.post_clients_run(&clients)

	if !testing.expect(t, cs.post_clients_was_successful(&clients, 0), "HTTP request should succeed") {
		return
	}

	_, body, _, _ := cs.post_clients_get_result(&clients, 0)
	testing.expect(t, string(body) == "hello", "echo response should match request body")
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

	url := cs.build_url("127.0.0.1", app^.port.(int), "/echo", context.temp_allocator)

	clients: cs.Post_Clients
	cs.post_clients_init(&clients, 1, context.allocator)
	defer cs.post_clients_destroy(&clients)

	cs.post_clients_set_task(&clients, 0, url, nil) // Empty body
	cs.post_clients_run(&clients)

	if !testing.expect(t, cs.post_clients_was_successful(&clients, 0), "HTTP request should succeed") {
		return
	}

	_, body, _, _ := cs.post_clients_get_result(&clients, 0)
	testing.expect(t, string(body) == "", "echo response should be empty for empty body")
}
