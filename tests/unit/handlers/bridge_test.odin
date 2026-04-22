//+test
// Unit tests for the bridge: verify Message round-trip through a minimal pipeline.
// Tests call pipeline directly — no HTTP server is started.
package test_unit_handlers

import pl "../../../pipeline"
import "matryoshka:."
import "core:testing"
import "core:thread"
import "core:time"

// echo_stage is a minimal Stage_Fn used in tests.
// It sends the message back to msg.reply_to (same as echo_worker in examples).
@(private)
echo_stage :: proc(me: ^pl.Master, _: pl.Mailbox, mi: ^pl.MayItem) {
	pl.reply_to_bridge(me, mi)
}

@(private)
Stage_Context :: pl.Stage_Context

// stage_proc mirrors spawn.odin stage_proc for test isolation.
@(private)
stage_proc :: proc(t: ^thread.Thread) {
	ctx := (^Stage_Context)(t.data)
	if ctx == nil {
		return
	}
	for {
		mi: pl.MayItem
		if matryoshka.mbox_wait_receive(ctx.me.inbox, &mi) != .Ok {
			break
		}
		ctx.fn(ctx.me, ctx.next, &mi)
		if mi != nil {
			pl.dtor(&ctx.me.builder, &mi)
		}
	}
}

@(test)
test_bridge_echo_round_trip :: proc(t: ^testing.T) {
	alloc := context.allocator

	// Create the worker master.
	m := pl.new_master(alloc)
	testing.expect(t, m != nil, "new_master should not return nil")

	ctx := Stage_Context {
		me   = m,
		next = nil,
		fn   = echo_stage,
	}

	// Start stage thread.
	stage_t := thread.create(stage_proc)
	testing.expect(t, stage_t != nil, "thread.create should not return nil")
	stage_t.data = &ctx
	stage_t.init_context = context
	thread.start(stage_t)

	// Create per-request reply mailbox (simulates what the bridge does).
	reply_mb := matryoshka.mbox_new(alloc)
	testing.expect(t, reply_mb != nil, "reply mailbox should not be nil")

	// Allocate a Message with a payload.
	b := pl.make_builder(alloc)
	mi := pl.ctor(&b)
	testing.expect(t, mi != nil, "ctor should return non-nil")

	ptr, _ := mi.?
	msg := (^pl.Message)(ptr)
	msg.payload = make([]byte, 5, alloc)
	copy(msg.payload, "hello")
	msg.reply_to = reply_mb

	// Send to worker.
	res_send := matryoshka.mbox_send(m.inbox, &mi)
	testing.expect(t, res_send == .Ok, "mbox_send should return .Ok")

	// Wait for reply (with timeout to avoid hanging on failure).
	reply_mi: pl.MayItem
	res_recv := matryoshka.mbox_wait_receive(reply_mb, &reply_mi, 2 * time.Second)
	testing.expect(t, res_recv == .Ok, "reply mailbox should receive response")
	testing.expect(t, reply_mi != nil, "reply should be non-nil")

	// Verify payload echoed back.
	if reply_mi != nil {
		rptr, rok := reply_mi.?
		testing.expect(t, rok, "reply unwrap should succeed")
		if rok {
			rmsg := (^pl.Message)(rptr)
			testing.expect(
				t,
				string(rmsg.payload) == "hello",
				"payload should be echoed unchanged",
			)
		}
		pl.dtor(&b, &reply_mi)
	}

	// Shutdown stage thread.
	matryoshka.mbox_close(m.inbox)
	thread.join(stage_t)
	thread.destroy(stage_t)

	// Close and dispose reply mailbox.
	matryoshka.mbox_close(reply_mb)
	mb_item: pl.MayItem = (^pl.PolyNode)(reply_mb)
	matryoshka.matryoshka_dispose(&mb_item)

	pl.free_master(m)
}

@(test)
test_message_payload_survives_transfer :: proc(t: ^testing.T) {
	alloc := context.allocator
	b := pl.make_builder(alloc)

	mi := pl.ctor(&b)
	testing.expect(t, mi != nil)

	ptr, _ := mi.?
	msg := (^pl.Message)(ptr)
	msg.payload = make([]byte, 3, alloc)
	copy(msg.payload, "abc")

	// Send to a mailbox and receive — payload must survive.
	mb := matryoshka.mbox_new(alloc)
	matryoshka.mbox_send(mb, &mi)
	testing.expect(t, mi == nil, "mi should be nil after send")

	mi_got: pl.MayItem
	matryoshka.mbox_wait_receive(mb, &mi_got, 0)

	gptr, _ := mi_got.?
	gmsg := (^pl.Message)(gptr)
	testing.expect(t, string(gmsg.payload) == "abc", "payload should survive mailbox transfer")

	pl.dtor(&b, &mi_got)

	matryoshka.mbox_close(mb)
	mb_item: pl.MayItem = (^pl.PolyNode)(mb)
	matryoshka.matryoshka_dispose(&mb_item)
}
