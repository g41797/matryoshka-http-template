// Ported directly from matryoshka/examples/block2/master.odin.
// Master is the universal processing unit used for every pipeline stage.
package pipeline

import "matryoshka:."
import list "core:container/intrusive/list"
import "core:mem"

// Master represents a pipeline stage context running on a thread.
// It owns its inbox (mailbox) and a builder for items.
// The same Master struct is used for translator_in, workers, and translator_out.
// Behavior is differentiated only by the processing callback — not by the struct.
Master :: struct {
	builder: Builder,
	inbox:   Mailbox,
	alloc:   mem.Allocator,
}

// new_master creates a new Master with a builder and an inbox.
new_master :: proc(alloc: mem.Allocator) -> ^Master {
	m, err := new(Master, alloc)
	if err != .None {
		return nil
	}
	m.alloc = alloc
	m.builder = make_builder(alloc)
	m.inbox = matryoshka.mbox_new(alloc)
	return m
}

// free_master performs clean teardown of a Master.
// The caller MUST join the worker thread before calling free_master.
free_master :: proc(m: ^Master) {
	if m == nil {
		return
	}

	// Close inbox and dispose remaining items.
	remaining := matryoshka.mbox_close(m.inbox)
	for {
		raw := list.pop_front(&remaining)
		if raw == nil {
			break
		}
		poly := (^PolyNode)(raw)
		mi: MayItem = poly
		dtor(&m.builder, &mi)
	}

	// Second close is idempotent — catches items that arrived during shutdown.
	remaining2 := matryoshka.mbox_close(m.inbox)
	for {
		raw := list.pop_front(&remaining2)
		if raw == nil {
			break
		}
		poly := (^PolyNode)(raw)
		mi: MayItem = poly
		dtor(&m.builder, &mi)
	}

	// Dispose the mailbox handle.
	mb_item: MayItem = (^PolyNode)(m.inbox)
	matryoshka.matryoshka_dispose(&mb_item)

	// Free Master memory.
	alloc := m.alloc
	free(m, alloc)
}
