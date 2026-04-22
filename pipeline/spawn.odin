// spawn provides stage thread lifecycle: spawn and shutdown.
// Adapted from block2 newMaster/freeMaster + thread.create/start/join patterns.
package pipeline

import "matryoshka:."
import "core:mem"
import "core:thread"

// spawn_stage starts a single pipeline stage thread for the given context.
// Returns nil on failure.
spawn_stage :: proc(ctx: ^Stage_Context, alloc: mem.Allocator) -> ^thread.Thread {
	t := thread.create(stage_proc)
	if t == nil {
		return nil
	}
	t.data = ctx
	t.init_context = context
	thread.start(t)
	return t
}

// spawn_workers starts n stage threads all reading from the same mailbox.
// All threads share the same Stage_Context (MPMC pattern from block2/fan_in_out.odin).
// Returns nil on allocation failure; caller must call shutdown_threads on partial success.
spawn_workers :: proc(n: int, ctx: ^Stage_Context, alloc: mem.Allocator) -> []^thread.Thread {
	threads := make([]^thread.Thread, n, alloc)
	for i in 0 ..< n {
		t := thread.create(stage_proc)
		if t == nil {
			// Return partial slice; caller handles cleanup.
			return threads[:i]
		}
		t.data = ctx
		t.init_context = context
		thread.start(t)
		threads[i] = t
	}
	return threads
}

// shutdown_threads joins and destroys a slice of stage threads.
shutdown_threads :: proc(threads: []^thread.Thread) {
	for t in threads {
		if t != nil {
			thread.join(t)
			thread.destroy(t)
		}
	}
}

// stage_proc is the generic thread procedure for all pipeline stages.
// The same proc runs for translator_in, workers, and translator_out.
// Behavior is determined solely by ctx.fn (the Stage_Fn callback).
//
// Loop:
//  1. Wait for an item on ctx.me.inbox.
//  2. Call ctx.fn(ctx.me, ctx.next, &mi) — fn owns mi and must transfer or free it.
//  3. If fn returned with mi still non-nil (error path), free it here.
//  4. Exit when inbox is closed.
stage_proc :: proc(t: ^thread.Thread) {
	ctx := (^Stage_Context)(t.data)
	if ctx == nil {
		return
	}

	for {
		mi: MayItem
		if matryoshka.mbox_wait_receive(ctx.me.inbox, &mi) != .Ok {
			break
		}
		ctx.fn(ctx.me, ctx.next, &mi)
		// Ownership guarantee: fn must consume mi (send or free).
		// If fn failed to transfer, free here to prevent leaks.
		if mi != nil {
			dtor(&ctx.me.builder, &mi)
		}
	}
}
