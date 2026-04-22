package pipeline

import "matryoshka:."
import "core:mem"

// Core type aliases from matryoshka.
PolyNode :: matryoshka.PolyNode
MayItem  :: matryoshka.MayItem
Mailbox  :: matryoshka.Mailbox
PolyTag  :: matryoshka.PolyTag

@(private)
message_tag: PolyTag = {}

// MESSAGE_TAG is the unique tag for Message items.
MESSAGE_TAG: rawptr = &message_tag

// message_is_it_you reports whether tag belongs to a Message.
message_is_it_you :: #force_inline proc(tag: rawptr) -> bool {return tag == MESSAGE_TAG}

// Message carries an HTTP request/response payload through the pipeline.
//
// payload holds the request or response body bytes.
// reply_to is a per-request mailbox owned by the bridge; the bridge blocks on it.
// The bridge sends Message into the pipeline; the terminal stage sends it back via reply_to.
//
// Ownership rules:
//   - payload bytes are owned by the Message; dtor frees them.
//   - reply_to is owned by the bridge; do not close or dispose it from pipeline stages.
//   - Message itself is owned via MayItem; transfer via mbox_send, free via dtor.
Message :: struct {
	using poly: PolyNode, // offset 0 — required for safe cast
	payload:    []byte,
	reply_to:   Mailbox,
}

// Builder allocates and frees Message items.
Builder :: struct {
	alloc: mem.Allocator,
}

// make_builder creates a Builder backed by the given allocator.
make_builder :: proc(alloc: mem.Allocator) -> Builder {
	return Builder{alloc = alloc}
}

// ctor allocates a new Message, sets its tag, and returns it as a MayItem.
// Returns nil on allocation failure.
ctor :: proc(b: ^Builder) -> MayItem {
	msg := new(Message, b.alloc)
	if msg == nil {
		return nil
	}
	msg.tag = MESSAGE_TAG
	return MayItem(&msg.poly)
}

// dtor frees the Message payload bytes and the node itself, then sets m^ = nil.
// Safe to call when m == nil or m^ == nil.
dtor :: proc(b: ^Builder, m: ^MayItem) {
	if m == nil {
		return
	}
	ptr, ok := m^.?
	if !ok {
		return
	}
	if message_is_it_you(ptr.tag) {
		msg := (^Message)(ptr)
		if len(msg.payload) > 0 {
			delete(msg.payload, b.alloc)
		}
		free(msg, b.alloc)
	}
	m^ = nil
}
