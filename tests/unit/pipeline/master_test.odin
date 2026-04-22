//+test
package test_unit_pipeline

import pl "../../../pipeline"
import "matryoshka:."
import "core:testing"

@(test)
test_ctor_dtor :: proc(t: ^testing.T) {
	b := pl.make_builder(context.allocator)

	mi := pl.ctor(&b)
	testing.expect(t, mi != nil, "ctor should return non-nil")

	ptr, ok := mi.?
	testing.expect(t, ok, "MayItem should be non-nil")
	testing.expect(t, ptr.tag == pl.MESSAGE_TAG, "tag should be MESSAGE_TAG")
	testing.expect(t, pl.message_is_it_you(ptr.tag), "message_is_it_you should return true")

	pl.dtor(&b, &mi)
	testing.expect(t, mi == nil, "mi should be nil after dtor")
}

@(test)
test_ctor_sets_payload_nil :: proc(t: ^testing.T) {
	b := pl.make_builder(context.allocator)
	mi := pl.ctor(&b)

	ptr, _ := mi.?
	msg := (^pl.Message)(ptr)
	testing.expect(t, len(msg.payload) == 0, "payload should be empty after ctor")
	testing.expect(t, msg.reply_to == nil, "reply_to should be nil after ctor")

	pl.dtor(&b, &mi)
}

@(test)
test_dtor_with_payload :: proc(t: ^testing.T) {
	b := pl.make_builder(context.allocator)
	mi := pl.ctor(&b)

	ptr, _ := mi.?
	msg := (^pl.Message)(ptr)
	msg.payload = make([]byte, 5, context.allocator)
	copy(msg.payload, "hello")

	// dtor must free the payload without panicking.
	pl.dtor(&b, &mi)
	testing.expect(t, mi == nil, "mi should be nil after dtor with payload")
}

@(test)
test_dtor_nil_safe :: proc(t: ^testing.T) {
	b := pl.make_builder(context.allocator)
	// Calling dtor on nil MayItem must not panic.
	mi: pl.MayItem = nil
	pl.dtor(&b, &mi) // should be a no-op
	pl.dtor(&b, nil) // should be a no-op
}

@(test)
test_new_free_master :: proc(t: ^testing.T) {
	m := pl.new_master(context.allocator)
	testing.expect(t, m != nil, "new_master should return non-nil")
	testing.expect(t, m.inbox != nil, "master inbox should be initialized")

	pl.free_master(m)
	// No assertions after free — just verify it does not panic.
}

@(test)
test_master_send_receive :: proc(t: ^testing.T) {
	m := pl.new_master(context.allocator)
	defer pl.free_master(m)

	// Create an item.
	mi := pl.ctor(&m.builder)
	testing.expect(t, mi != nil, "ctor should succeed")

	// Send to master's own inbox.
	res_send := matryoshka.mbox_send(m.inbox, &mi)
	testing.expect(t, res_send == .Ok, "mbox_send should return .Ok")
	testing.expect(t, mi == nil, "mi should be nil after send")

	// Receive it back.
	mi_got: pl.MayItem
	res_recv := matryoshka.mbox_wait_receive(m.inbox, &mi_got, 0)
	testing.expect(t, res_recv == .Ok, "mbox_wait_receive should return .Ok")
	testing.expect(t, mi_got != nil, "mi_got should be non-nil after receive")

	pl.dtor(&m.builder, &mi_got)
}

@(test)
test_message_tag_is_unique :: proc(t: ^testing.T) {
	// Verify the tag pointer is stable across calls.
	t1 := pl.MESSAGE_TAG
	t2 := pl.MESSAGE_TAG
	testing.expect(t, t1 == t2, "MESSAGE_TAG should be the same pointer across calls")
	testing.expect(t, t1 != nil, "MESSAGE_TAG should not be nil")
}
