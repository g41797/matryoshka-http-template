//+test
// Smoke test for the async machinery.
// Uses the "Split Handler" pattern: mark_async + resume called from the same thread.
package test_async

import http "../../../vendor/odin-http"
import client "../../../vendor/odin-http/client"
import cs "../../../http_cs"
import "core:bytes"
import "core:testing"
import "core:time"

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

Split_Test_Server :: struct {
        using base: cs.Base_Server,
}

@(test)
test_split_async_smoke :: proc(t: ^testing.T) {
        ptr := new(Split_Test_Server, context.allocator)
        if !testing.expect(t, ptr != nil, "alloc failed") { return }

        cs.base_server_init(ptr, context.allocator)
        ptr.route_handler = http.Handler{handle = split_ping_handler}

        if !testing.expect(t, cs.base_server_start(ptr), "server failed to start") {
                free(ptr, context.allocator)
                return
        }

        req: client.Request
        client.request_init(&req, .Post)
        defer client.request_destroy(&req)
        bytes.buffer_write_string(&req.body, "ping")

        url := cs.build_url("127.0.0.1", ptr.port.(int), "/", context.temp_allocator)
        res, err := client.request(&req, url)
        if !testing.expect(t, err == nil, "HTTP request should succeed") {
                cs.base_server_shutdown(ptr)
                cs.base_server_wait(ptr, 5 * time.Second)
                free(ptr, context.allocator)
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

        cs.base_server_shutdown(ptr)
        cs.base_server_wait(ptr, 5 * time.Second)
        free(ptr, context.allocator)
}
