// Bridge is the boundary between odin-http and the matryoshka pipeline.
// This is the ONLY file in the template that imports both http and pipeline types.
// No http types appear in pipeline/ or runtime/.
package adapter_http

import http "../../vendor/odin-http"
import matryoshka "../../vendor/matryoshka"
import pl "../../pipeline"
import "core:mem"

// Bridge converts an HTTP request to a pipeline Message, sends it through
// the pipeline, and converts the response Message back to an HTTP response.
//
// Ownership:
//   - Bridge creates a per-request reply mailbox (closed after response is received).
//   - Bridge creates the request Message and transfers ownership into the pipeline.
//   - The terminal pipeline stage sends the response Message to reply_to.
//   - Bridge receives the response, reads it, and frees the Message.
Bridge :: struct {
	// inbox is the mailbox of the first pipeline stage (worker or translator_in).
	inbox:   pl.Mailbox,
	builder: pl.Builder,
	alloc:   mem.Allocator,
}

// bridge_init creates a Bridge backed by the given allocator.
bridge_init :: proc(inbox: pl.Mailbox, alloc: mem.Allocator) -> Bridge {
	return Bridge{
		inbox   = inbox,
		builder = pl.make_builder(alloc),
		alloc   = alloc,
	}
}

// bridge_handle is the entry point called from an odin-http handler.
// It reads the request body, sends it through the pipeline, and writes the response.
// Blocks the calling thread until the pipeline stage replies.
bridge_handle :: proc(b: ^Bridge, req: ^http.Request, res: ^http.Response) {
	Ctx :: struct {
		b:   ^Bridge,
		res: ^http.Response,
	}
	ctx := Ctx{b = b, res = res}
	http.body(req, -1, &ctx, proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
		ctx := (^Ctx)(user_data)
		b   := ctx.b
		res := ctx.res

		if err != nil {
			res.status = .Internal_Server_Error
			http.respond(res)
			return
		}

		// Create per-request reply mailbox (owned by bridge for this request).
		reply_mb := matryoshka.mbox_new(b.alloc)
		if reply_mb == nil {
			res.status = .Internal_Server_Error
			http.respond(res)
			return
		}
		// Single teardown covers all exit paths — error and success alike.
		defer {
			matryoshka.mbox_close(reply_mb)
			mb_item: pl.MayItem = (^pl.PolyNode)(reply_mb)
			matryoshka.matryoshka_dispose(&mb_item)
		}

		// Allocate Message and copy payload from HTTP body.
		mi := pl.ctor(&b.builder)
		if mi == nil {
			res.status = .Internal_Server_Error
			http.respond(res)
			return
		}
		// Ownership of mi transfers to the pipeline on successful mbox_send.
		sent := false
		defer if !sent { pl.dtor(&b.builder, &mi) }

		ptr, _ := mi.?
		msg := (^pl.Message)(ptr)
		msg.reply_to = reply_mb

		// Copy body bytes (HTTP body string is borrowed from odin-http's buffer).
		if len(body) > 0 {
			msg.payload = make([]byte, len(body), b.alloc)
			copy(msg.payload, body)
		}

		// Send to pipeline — ownership of mi transfers on success.
		if matryoshka.mbox_send(b.inbox, &mi) != .Ok {
			res.status = .Internal_Server_Error
			http.respond(res)
			return
		}
		sent = true

		// Block waiting for the pipeline response.
		reply_mi: pl.MayItem
		if matryoshka.mbox_wait_receive(reply_mb, &reply_mi) != .Ok {
			res.status = .Internal_Server_Error
			http.respond(res)
			return
		}

		// Read response payload and write HTTP response.
		reply_ptr, reply_ok := reply_mi.?
		if reply_ok {
			reply_msg := (^pl.Message)(reply_ptr)
			http.respond_plain(res, string(reply_msg.payload))
		} else {
			res.status = .Internal_Server_Error
			http.respond(res)
		}

		// Free response Message (bridge owns it after receiving from reply_to).
		pl.dtor(&b.builder, &reply_mi)
		// reply_mb defer fires here.
	})
}
