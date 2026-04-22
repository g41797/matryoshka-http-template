package test_unit_http_cs

import ex "../../../examples"
import cs "../../../http_cs/"
import "core:testing"

@(test)
test_Post_Client :: proc(t: ^testing.T) {
	app := ex.example_echo_start(0, context.allocator)
	if !testing.expect(t, app != nil, "echo server should start") {
		return
	}
	defer ex.example_echo_stop(app)

	url := cs.build_url("127.0.0.1", app^.port.(int), "/echo", context.temp_allocator)

	clients: cs.Post_Clients
	ok := cs.post_clients_init(&clients, 1, context.allocator)
	testing.expect(t, ok, "post_clients_init should succeed")
	defer cs.post_clients_destroy(&clients)

	s := "Hello, World!"
	cs.post_clients_set_task(&clients, 0, url, transmute([]u8)s)
	cs.post_clients_run(&clients)

	testing.expect(t, cs.post_clients_was_successful(&clients, 0), "post should succeed")

	status, body, _, err := cs.post_clients_get_result(&clients, 0)
	testing.expect(t, err == .None, "no post_client error expected")
	testing.expect(t, status == .OK, "http status should be OK")
	testing.expect(t, string(body) == "Hello, World!", "echo response should match")
}

@(test)
test_Post_Client_multiple :: proc(t: ^testing.T) {
	app := ex.example_echo_start(0, context.allocator)
	if !testing.expect(t, app != nil, "echo server should start") {
		return
	}
	defer ex.example_echo_stop(app)

	url := cs.build_url("127.0.0.1", app^.port.(int), "/echo", context.temp_allocator)

	clients: cs.Post_Clients
	ok := cs.post_clients_init(&clients, 3, context.allocator)
	testing.expect(t, ok, "post_clients_init should succeed")
	defer cs.post_clients_destroy(&clients)

	s := "Hello, World!"
	for i in 0 ..< 3 {
		cs.post_clients_set_task(&clients, i, url, transmute([]u8)s)
	}

	cs.post_clients_run(&clients)

	for i in 0 ..< 3 {
		testing.expectf(t, cs.post_clients_was_successful(&clients, i), "post %d should succeed", i)
		status, body, _, err := cs.post_clients_get_result(&clients, i)
		testing.expectf(t, err == .None, "post %d should have no post_client error", i)
		testing.expectf(t, status == .OK, "post %d http status should be OK", i)
		testing.expectf(t, string(body) == "Hello, World!", "post %d echo response should match", i)
	}
}
