// Pipeline assembly: create mailboxes, connect Masters, configure stage contexts.
// Adapted from matryoshka/examples/block2/pipeline.odin.
//
// All wiring lives here — no pipeline logic is duplicated across packages.
package pipeline

import "matryoshka:."
import "core:mem"

// Stage_Fn is the processing callback for a pipeline stage.
// me is the owning Master (builder, inbox).
// next is the mailbox of the following stage (nil if the stage replies directly via msg.reply_to).
// mi holds the item on entry; the fn must transfer or free it before returning.
// After a successful mbox_send, mi^ is nil. The caller frees mi if it is still non-nil on return.
Stage_Fn :: #type proc(me: ^Master, next: Mailbox, mi: ^MayItem)

// Stage_Context bundles a Master with its downstream mailbox and processing function.
// Created by build_echo_pipeline or build_full_pipeline; passed to runtime.spawn_stage.
Stage_Context :: struct {
	me:   ^Master,
	next: Mailbox,
	fn:   Stage_Fn,
}

// EchoPipeline is a single-stage pipeline: bridge → worker → bridge.
// The worker receives a Message and echoes it back via msg.reply_to.
EchoPipeline :: struct {
	worker: Stage_Context,
}

// build_echo_pipeline creates a single-worker echo pipeline.
// The caller is responsible for freeing via free_echo_pipeline.
build_echo_pipeline :: proc(fn: Stage_Fn, alloc: mem.Allocator) -> (p: EchoPipeline, ok: bool) {
	m := new_master(alloc)
	if m == nil {
		return p, false
	}
	p.worker = Stage_Context{me = m, next = nil, fn = fn}
	return p, true
}

// free_echo_pipeline tears down the pipeline. Call after all stage threads have joined.
free_echo_pipeline :: proc(p: ^EchoPipeline) {
	free_master(p.worker.me)
}

// FullPipeline is a three-stage pipeline:
// bridge → translator_in → worker → translator_out → bridge.
// The worker mailbox is shared; multiple workers can read from it (MPMC).
FullPipeline :: struct {
	translator_in:  Stage_Context,
	worker:         Stage_Context, // worker.me.inbox is the shared mailbox
	translator_out: Stage_Context,
}

// build_full_pipeline creates a three-stage pipeline connected by mailboxes.
// The caller is responsible for freeing via free_full_pipeline.
build_full_pipeline :: proc(
	translate_in_fn:  Stage_Fn,
	worker_fn:        Stage_Fn,
	translate_out_fn: Stage_Fn,
	alloc: mem.Allocator,
) -> (p: FullPipeline, ok: bool) {
	m_in  := new_master(alloc)
	m_w   := new_master(alloc)
	m_out := new_master(alloc)

	if m_in == nil || m_w == nil || m_out == nil {
		free_master(m_in)
		free_master(m_w)
		free_master(m_out)
		return p, false
	}

	// translator_in forwards to the shared worker mailbox.
	p.translator_in  = Stage_Context{me = m_in,  next = m_w.inbox,  fn = translate_in_fn}
	// worker forwards to translator_out.
	p.worker         = Stage_Context{me = m_w,   next = m_out.inbox, fn = worker_fn}
	// translator_out sends reply via msg.reply_to (next == nil).
	p.translator_out = Stage_Context{me = m_out, next = nil,         fn = translate_out_fn}

	return p, true
}

// free_full_pipeline tears down the pipeline. Call after all stage threads have joined.
free_full_pipeline :: proc(p: ^FullPipeline) {
	// Close in reverse order (downstream first) so remaining items can drain.
	free_master(p.translator_out.me)
	free_master(p.worker.me)
	free_master(p.translator_in.me)
}

// forward_to_next sends mi to next. On failure, frees mi using me's builder.
// Adapted from block2/pipeline.odin transformer_proc forwarding logic.
forward_to_next :: proc(me: ^Master, next: Mailbox, mi: ^MayItem) {
	if matryoshka.mbox_send(next, mi) != .Ok {
		dtor(&me.builder, mi)
	}
}

// reply_to_bridge sends mi to the per-request reply mailbox embedded in the Message.
// Used by translator_out (or directly by a worker in echo pipelines).
// On failure, frees mi using me's builder.
reply_to_bridge :: proc(me: ^Master, mi: ^MayItem) {
	ptr, ok := mi^.?
	if !ok {
		dtor(&me.builder, mi)
		return
	}
	msg := (^Message)(ptr)
	if matryoshka.mbox_send(msg.reply_to, mi) != .Ok {
		dtor(&me.builder, mi)
	}
}
