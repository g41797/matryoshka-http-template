package examples_async

import http "../../vendor/odin-http"
import "core:thread"
import "core:mem"
import "core:time"
import cs "../../http_cs"

Body_Context :: struct {
        alloc: mem.Allocator,
}

Body_Work :: struct {
        alloc:  mem.Allocator,
        thread: ^thread.Thread,
        body:   string,
        result: string,
}

body_background_proc :: proc(t: ^thread.Thread) {
        res := (^http.Response)(t.data)
        work := (^Body_Work)(res.async_state)

        // Simulate work using the body.
        time.sleep(10 * time.Millisecond)
        work.result = work.body

        http.resume(res)
}

body_callback :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
        res := (^http.Response)(user_data)
        ctx := (^Body_Context)(res.async_handler.user_data)

        if err != nil {
                http.respond(res, http.body_error_status(err))
                return
        }

        work := new(Body_Work, ctx.alloc)
        work.alloc = ctx.alloc
        work.body = string(body)

        // mark_async uses the handler stored earlier.
        http.mark_async(res.async_handler, res, work)

        t := thread.create(body_background_proc)
        if t == nil {
                http.cancel_async(res)
                free(work, ctx.alloc)
                http.respond(res, http.Status.Internal_Server_Error)
                return
        }
        t.data = res
        work.thread = t
        thread.start(t)
}

body_handler_proc :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
        if res.async_state == nil {
                // Store handler for later use in callback.
                res.async_handler = h
                http.body(req, -1, res, body_callback)
                return
        }

        work := (^Body_Work)(res.async_state)
        defer {
                thread.join(work.thread)
                thread.destroy(work.thread)
                free(work, work.alloc)
                res.async_state = nil
        }

        http.respond_plain(res, work.result)
}

// --- Test Infrastructure ---

BodyApp :: struct {
        using base: cs.Base_Server,
        ctx:        ^Body_Context,
}

body_async_start :: proc(port: int, alloc: mem.Allocator) -> ^BodyApp {
        s: Maybe(^BodyApp)

        for {
                ptr := new(BodyApp, alloc)
                if ptr == nil {
                        break
                }
                s = ptr

                if !cs.base_server_init(ptr, alloc) {
                        break
                }
                ptr.endpoint.port = port

                ctx := new(Body_Context, alloc)
                if ctx == nil {
                        ptr.error = .user_error
                        break
                }
                ctx.alloc = alloc
                ptr.ctx = ctx

                h := http.Handler {
                        handle    = body_handler_proc,
                        user_data = ptr.ctx,
                }

                if !cs.base_router_init(ptr) {
                        break
                }
                if !cs.base_router_post(ptr, "/body", h) {
                        break
                }
                if !cs.base_router_handler(ptr) {
                        break
                }
                if !cs.base_server_start(ptr) {
                        break
                }

                break
        }

        app, ok := s.(^BodyApp)
        if !ok {
                return nil
        }
        if app.error != .none {
                body_async_stop(app)
                return nil
        }
        return app
}

body_async_stop :: proc(app: ^BodyApp) {
        if app == nil {
                return
        }
        cs.base_server_shutdown(app)
        cs.base_server_wait(app, 5 * time.Second)
        if app.ctx != nil {
                free(app.ctx, app.alloc)
        }
        cs.base_router_destroy(app)
        free(app, app.alloc)
}
