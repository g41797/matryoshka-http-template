package examples_async

import http "http:."
import "core:mem"
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
        using base: cs.Base_Server,
}

split_async_start :: proc(port: int, alloc: mem.Allocator) -> ^SplitApp {
        s: Maybe(^SplitApp)

        for {
                ptr := new(SplitApp, alloc)
                if ptr == nil { break }
                s = ptr

                if !cs.base_server_init(ptr, alloc) { break }
                ptr.endpoint.port = port
                ptr.route_handler  = http.Handler{handle = split_handler_proc}

                if !cs.base_server_start(ptr) { break }

                break
        }

        app, ok := s.(^SplitApp)
        if !ok { return nil }
        if app.error != .none {
                split_async_stop(app)
                return nil
        }
        return app
}

split_async_stop :: proc(app: ^SplitApp) {
        if app == nil { return }
        cs.base_server_shutdown(app)
        cs.base_server_destroy(app)
}
