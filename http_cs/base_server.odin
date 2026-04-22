package http_cs

import http "../vendor/odin-http"
import "core:mem"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

Base_Server_Error :: enum {
    none,
    thread_create_failed,
    listen_failed,
    serve_failed,
    user_error,
}

Base_Server :: struct {
    alloc:         mem.Allocator,
    server:        http.Server,
    router:        Maybe(http.Router),
    route_handler: Maybe(http.Handler),
    server_thread: Maybe(^thread.Thread),
    ready:         sync.Sema,
    done:          sync.Sema,
    port:          Maybe(int),
    listen_err:    Maybe(net.Network_Error),
    serve_err:     Maybe(net.Network_Error),
    endpoint:      net.Endpoint,
    opts:          http.Server_Opts,
    error:         Base_Server_Error,
}

// Sets alloc, loopback ephemeral endpoint, thread_count=1 opts. Always returns true.
base_server_init :: proc(s: ^Base_Server, alloc: mem.Allocator) -> (ok: bool) {
    s.alloc    = alloc
    s.endpoint = net.Endpoint{address = net.IP4_Loopback, port = 0}
    s.opts     = http.Default_Server_Opts
    s.opts.thread_count = 1
    return true
}

// Init router on s.alloc. Always returns true.
base_router_init :: proc(s: ^Base_Server) -> (ok: bool) {
    r: http.Router
    http.router_init(&r, s.alloc)
    s.router = r
    return true
}

// Register a POST route. Requires base_router_init called. Always returns true.
base_router_post :: proc(s: ^Base_Server, path: string, handler: http.Handler) -> (ok: bool) {
    http.route_post(&s.router.(http.Router), path, handler)
    return true
}

// Build top-level handler from router, store in s.route_handler. Always returns true.
base_router_handler :: proc(s: ^Base_Server) -> (ok: bool) {
    s.route_handler = http.router_handler(&s.router.(http.Router))
    return true
}

// Internal — runs on the server thread.
@(private)
base_server_thread :: proc(t: ^thread.Thread) {
    s := (^Base_Server)(t.data)
    defer sync.sema_post(&s.done)

    handler, has := s.route_handler.(http.Handler)
    if !has {
        s.error = .serve_failed
        sync.sema_post(&s.ready)
        return
    }

    err := http.listen(&s.server, s.endpoint, s.opts)
    if err != nil {
        s.listen_err = err
        s.error      = .listen_failed
        sync.sema_post(&s.ready)
        return
    }

    if p, ok := get_listening_port(&s.server); ok {
        s.port = p
    }

    sync.sema_post(&s.ready)

    serve_err := http.serve(&s.server, handler)
    if serve_err != nil {
        s.serve_err = serve_err
        if s.error == .none {
            s.error = .serve_failed
        }
    }
}

// Start server thread. Blocks until http.listen completes (ready signal).
// Sets s.port on success. Sets s.error and returns false on failure.
base_server_start :: proc(s: ^Base_Server) -> (ok: bool) {
    t := thread.create(base_server_thread)
    if t == nil {
        s.error = .thread_create_failed
        return false
    }

    t.data         = s
    t.init_context = context
    thread.start(t)
    s.server_thread = t

    sync.sema_wait(&s.ready)
    return s.error == .none
}

// Signal server to stop. No-op if thread was never started.
base_server_shutdown :: proc(s: ^Base_Server) {
    _, has := s.server_thread.(^thread.Thread)
    if !has { return }
    http.server_shutdown(&s.server)
}

// Wait for server to finish. Returns false if timeout elapsed (server may still be running).
// Returns true if server finished within timeout; s.error reflects exit status.
base_server_wait :: proc(s: ^Base_Server, timeout: time.Duration) -> (ok: bool) {
	t, has := s.server_thread.(^thread.Thread)
	if !has {
		return true
	}
	if !sync.sema_wait_with_timeout(&s.done, timeout) {
		return false
	}
	thread.join(t)
	thread.destroy(t)
	s.server_thread = nil
	return s.error == .none
}

// Destroy router. No-op if never initialized.
base_router_destroy :: proc(s: ^Base_Server) {
	_, ok := s.router.(http.Router)
	if !ok {
		return
	}
	http.router_destroy(&s.router.(http.Router))
	s.router = nil
}

// Blocking wait + base_router_destroy + free(s, s.alloc).
// Must be called after base_server_shutdown.
base_server_destroy :: proc(s: ^Base_Server) {
	if s == nil {
		return
	}
	t, ok := s.server_thread.(^thread.Thread)
	if ok {
		sync.sema_wait(&s.done)
		thread.join(t)
		thread.destroy(t)
		s.server_thread = nil
	}
	base_router_destroy(s)
	free(s, s.alloc)
}

