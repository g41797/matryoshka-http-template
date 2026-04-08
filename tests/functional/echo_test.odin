//+test
// Functional test: starts the echo HTTP server, sends a POST request, asserts the response.
// Follows matryoshka's philosophy: tests call example functions directly,
// without duplicating logic.
package test_functional

import ex "../../examples"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_echo_http_round_trip :: proc(t: ^testing.T) {
	// Start the echo server (binds TCP immediately; serves in background thread).
	app := ex.example_echo_start(18080, context.allocator)
	if !testing.expect(t, app != nil, "example_echo_start should succeed") {
		return
	}
	defer ex.example_echo_stop(app)

	// Give the event loop a moment to begin accepting connections.
	time.sleep(50 * time.Millisecond)

	body := send_post("127.0.0.1", 18080, "/echo", "hello", t)
	testing.expect(t, body == "hello", "echo response should match request body")
}

@(test)
test_echo_empty_body :: proc(t: ^testing.T) {
	app := ex.example_echo_start(18081, context.allocator)
	if !testing.expect(t, app != nil, "example_echo_start should succeed") {
		return
	}
	defer ex.example_echo_stop(app)

	time.sleep(50 * time.Millisecond)

	body := send_post("127.0.0.1", 18081, "/echo", "", t)
	testing.expect(t, body == "", "echo response should be empty for empty body")
}

// send_post sends a minimal HTTP/1.1 POST request over raw TCP and returns the response body.
// Uses core:net directly to avoid a dependency on odin-http client in tests.
@(private)
send_post :: proc(host: string, port: int, path: string, body: string, t: ^testing.T) -> string {
	endpoint := net.Endpoint{
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}

	sock, err := net.dial_tcp_from_endpoint(endpoint)
	if !testing.expect(t, err == nil, "TCP dial should succeed") {
		return ""
	}
	defer net.close(sock)

	// Build a minimal HTTP/1.1 POST request.
	req := strings.concatenate(
		{
			"POST ", path, " HTTP/1.1\r\n",
			"Host: ", host, "\r\n",
			"Content-Type: text/plain\r\n",
			"Content-Length: ", int_to_str(len(body)), "\r\n",
			"Connection: close\r\n",
			"\r\n",
			body,
		},
		context.temp_allocator,
	)

	_, send_err := net.send_tcp(sock, transmute([]byte)req)
	if !testing.expect(t, send_err == nil, "TCP send should succeed") {
		return ""
	}

	// Read the full response.
	buf := make([]byte, 4096, context.temp_allocator)
	n, recv_err := net.recv_tcp(sock, buf)
	if !testing.expect(t, recv_err == nil || n > 0, "TCP recv should succeed") {
		return ""
	}

	response := string(buf[:n])

	// Extract body after the blank line separating headers and body.
	sep := "\r\n\r\n"
	idx := strings.index(response, sep)
	if idx < 0 {
		return ""
	}
	return strings.clone(response[idx + len(sep):], context.temp_allocator)
}

@(private)
int_to_str :: proc(n: int) -> string {
	buf := make([]byte, 20, context.temp_allocator)
	s := len(buf)
	v := n
	if v == 0 {
		return "0"
	}
	for v > 0 {
		s -= 1
		buf[s] = byte('0' + v % 10)
		v /= 10
	}
	return string(buf[s:])
}
