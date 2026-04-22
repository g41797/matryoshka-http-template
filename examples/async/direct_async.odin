package examples_async

import http "http:."
import "core:thread"
import "core:mem"
import "core:time"
import cs "../../http_cs"

// Context shared by handlers, set at route registration.
Direct_Context :: struct {
        alloc: mem.Allocator,
}

// Work allocated for each request.
Direct_Work :: struct {
        alloc:  mem.Allocator,
        thread: ^thread.Thread,
        result: string,
}

// Background work procedure.
direct_background_proc :: proc(t: ^thread.Thread) {
        res := (^http.Response)(t.data)
        work := (^Direct_Work)(res.async_state)

        // Simulate some slow work.
        time.sleep(10 * time.Millisecond)
        work.result = "hello from background"

        // Signal the io thread.
        http.resume(res)
}

// Handler procedure.
direct_handler_proc :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
        ctx := (^Direct_Context)(h.user_data)

        if res.async_state == nil {
                // Part 1: First call.
                work := new(Direct_Work, ctx.alloc)
                work.alloc = ctx.alloc

                // Preparation -> mark_async -> start work.
                http.mark_async(h, res, work)

                t := thread.create(direct_background_proc)
                if t == nil {
                        // Roll back if thread creation fails.
                        http.cancel_async(res)
                        free(work, ctx.alloc)
                        http.respond(res, http.Status.Internal_Server_Error)
                        return
                }
                t.data = res
                work.thread = t
                thread.start(t)
                return
        }

        // Part 2: Resume call.
        work := (^Direct_Work)(res.async_state)
        defer {
                thread.join(work.thread)
                thread.destroy(work.thread)
                free(work, work.alloc)
                res.async_state = nil
        }

        http.respond_plain(res, work.result)
}

// --- Test Infrastructure ---

DirectApp :: struct {
        using base: cs.Base_Server,
        ctx:        ^Direct_Context,
}

direct_async_start :: proc(port: int, alloc: mem.Allocator) -> ^DirectApp {
        s: Maybe(^DirectApp)

        for {
                ptr := new(DirectApp, alloc)
                if ptr == nil { break }
                s = ptr

                if !cs.base_server_init(ptr, alloc) { break }
                ptr.endpoint.port = port

                ctx := new(Direct_Context, alloc)
                if ctx == nil { ptr.error = .user_error; break }
                ctx.alloc = alloc
                ptr.ctx = ctx

                h := http.Handler{
                        handle    = direct_handler_proc,
                        user_data = ptr.ctx,
                }

                // direct used GET, now uses POST to match the new Base Client.
                if !cs.base_router_init(ptr) { break }
                if !cs.base_router_post(ptr, "/direct", h) { break }
                if !cs.base_router_handler(ptr) { break }
                if !cs.base_server_start(ptr)  { break }

                break
        }

        app, ok := s.(^DirectApp)
        if !ok { return nil }
        if app.error != .none {
                direct_async_stop(app)
                return nil
        }
        return app
}

direct_async_stop :: proc(app: ^DirectApp) {
        if app == nil { return }
        cs.base_server_shutdown(app)
        cs.base_server_wait(app, 5 * time.Second)
        if app.ctx != nil {
                free(app.ctx, app.alloc)
        }
        cs.base_router_destroy(app)
        free(app, app.alloc)
}
