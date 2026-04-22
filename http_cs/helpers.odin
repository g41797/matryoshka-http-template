package http_cs

import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"


import http "http:."


// returns actual listening port.
// useful for the testing, when listening port == 0
// (automatically allocate a free ephemeral port).
get_listening_port :: proc(s: ^http.Server) -> (port: int, ok: bool) {
	if s.tcp_sock == 0 {return 0, false}
	ep, err := net.bound_endpoint(s.tcp_sock)
	if err != nil {return 0, false}
	return ep.port, true
}


// url builder for HTTP POST.
// creates url http://scooterlabs.com:80/echo
// for
// - host_or_ip = scooterlabs.com
// - port = 80
// - path = 'echo' or '/echo'
//
// don't forget free allocated memory after usage:
// delete(url, allocator)
build_url :: proc(
	host_or_ip: string,
	port: int,
	path: string,
	alctr: mem.Allocator,
) -> (
	url: string,
) {
	return fmt.aprintf(
		"http://%s:%d/%s",
		host_or_ip,
		port,
		strings.trim_left(path, "/"),
		allocator = alctr,
	)
}
