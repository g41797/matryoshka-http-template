// Package pipeline provides the core concurrency primitives for building
// HTTP server pipelines on top of matryoshka.
//
// All message types must embed PolyNode at offset 0.
// All concurrency is explicit via matryoshka mailboxes.
// No HTTP types appear in this package.
package pipeline
