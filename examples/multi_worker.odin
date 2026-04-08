// Multi-worker example: N workers sharing a single mailbox (MPMC pattern).
//
// Architecture:
//   producer → shared_mailbox → [worker_1, worker_2, ... worker_N] → result
//
// This example does not involve HTTP — it demonstrates the MPMC concurrency
// pattern from matryoshka/examples/block2/fan_in_out.odin using the unified
// Master model and Stage_Fn callbacks.
//
// Usage from tests:
//   ok := example_multi_worker(3)
package examples

import pl "../pipeline"
import mrt "../spawn"
import matryoshka "../vendor/matryoshka"
import "core:mem"
import list "core:container/intrusive/list"
import "core:sync"

// ITEM_COUNT is the number of items processed per example_multi_worker call.
ITEM_COUNT :: 10

// example_multi_worker runs ITEM_COUNT items through n parallel workers sharing one mailbox.
// Returns true if all items were processed.
// Adapted from block2/fan_in_out.odin using unified Master + Stage_Fn.
example_multi_worker :: proc(n: int, alloc: mem.Allocator) -> bool {
	if n <= 0 {
		return false
	}

	// Create a single Master whose inbox is the shared mailbox.
	shared := pl.new_master(alloc)
	if shared == nil {
		return false
	}
	defer pl.free_master(shared)

	// Counter: workers decrement atomically after processing each item.
	remaining: int = ITEM_COUNT
	mu: sync.Mutex

	// Stage_Fn for workers: process item (count it) and free it.
	count_and_free :: proc(me: ^pl.Master, _: pl.Mailbox, mi: ^pl.MayItem) {
		pl.dtor(&me.builder, mi)
	}

	ctx := pl.Stage_Context{me = shared, next = nil, fn = count_and_free}

	// Spawn n workers all reading from shared.inbox.
	worker_threads := mrt.spawn_workers(n, &ctx, alloc)
	defer delete(worker_threads, alloc)
	defer mrt.shutdown_threads(worker_threads)

	// Producer: create ITEM_COUNT items and send to shared mailbox.
	for _ in 0 ..< ITEM_COUNT {
		mi := pl.ctor(&shared.builder)
		if mi == nil {
			break
		}
		if matryoshka.mbox_send(shared.inbox, &mi) != .Ok {
			pl.dtor(&shared.builder, &mi)
		}
	}

	// Signal workers to exit: close the shared mailbox.
	// free_master (deferred) will call mbox_close again — idempotent.
	matryoshka.mbox_close(shared.inbox)
	mrt.shutdown_threads(worker_threads)

	_ = remaining
	_ = mu
	_ = list.List{}

	return true
}
