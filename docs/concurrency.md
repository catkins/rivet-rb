# Concurrency and shutdown

[README](../README.md) · [API](api.md) · [SQLite](sqlite.md) · [Development](development.md)

## Ordinary Ruby threads

Use this binding from ordinary Ruby threads in the **main Ractor**. Clients and actor handles
can issue native requests from multiple threads. Resolve a shared creating handle before fan-out
as described in the [historical cold-creation warning](api.md#historical-cold-creation-race).
This does not make every resource or application object safe for concurrent mutation:

- Actions, client queue handlers and HTTP handlers share an action mutex per actor instance.
  They run one at a time within that instance, even when a handler releases the GVL for I/O.
  Different actors can progress concurrently; execution order is not guaranteed.
  Avoid synchronous self-calls and cyclic actor-to-actor calls.
- Lifecycle, connection and background `run` hooks do not take the action mutex and can overlap
  work handlers. Use `ctx.update_state` for atomic actor-state updates, keep its block short and
  free of I/O, and synchronize instance variables shared between hooks and actions yourself.
- Start a registry once at a time. Another Ruby thread can call `registry.stop`; callbacks must
  cooperate with cancellation and shutdown.
- Give connections, subscriptions and SQL transactions one owner, or coordinate use yourself.
  Do not race `on` with `close`, close resources another thread uses, or share a transaction
  between independent operations. Use either a subscription listener or manual polling;
  the two consumers otherwise compete. Listener blocks run on Ruby threads, so synchronize
  application data they share with other threads.

## GVL and native I/O

The extension releases MRI's Global VM Lock (GVL) while waiting for native client requests,
SQL, queue operations and callback/event polling. Rust's shared multi-threaded Tokio runtime
can work while other Ruby threads run. Ruby argument conversion happens before releasing the
GVL; result conversion and exception creation happen after reacquiring it. Tokio workers do
not call Ruby: channels deliver actor callbacks to Ruby-created threads.

This overlaps I/O, **not CPU-heavy Ruby execution within one Ractor**. Callback worker limits
are admission limits, not Ruby CPU cores. Value conversion and other Ruby code still use the
GVL. There is no Fiber scheduler integration.

Releasing the GVL is not cancellation: the native wrapper supplies no unblock function.
Do not rely on Ruby `Timeout` or `Thread#kill` to cancel native I/O. Use
[operation deadlines](api.md#timeouts-and-errors) and cooperative callback cancellation;
neither rolls back remote actions or external effects.

## Callback admission

`registry.start(workers: 16, lifecycle_workers: 4, background_workers: 16, shutdown_timeout: 45)`
caps live work, lifecycle and background threads separately. Background hooks share the work
channel; work and lifecycle channels each hold at most 64 pending callbacks. Excess work fails
with Rivet's overload error instead of allocating more threads. Waiting for an actor's action
lock also consumes a work slot.

Lifecycle capacity is reserved but finite, not a guarantee against hook overload. These are
bridge admission limits, not bounds on upstream runtime memory or buffered HTTP bodies.

## Shutdown and cancellation

Cancellation cannot forcibly interrupt Ruby code or external side effects. Check `ctx.aborted?`
for cooperative cancellation; stale callbacks cannot use `update_state` after their native
reply closes.

`registry.stop` requests shutdown. `start` keeps dispatching cleanup until completion or the
shutdown deadline, then cancels replies and aborts the runner task. On timeout it raises
`Rivet::TimeoutError`; it does not kill Ruby threads, guarantee final persistence, or permit
restart while callbacks live. Deadlines require MRI to schedule the dispatcher; native
extensions retaining the GVL can delay it.

Subscription listener joins have their own bounded cleanup; see
[clients and subscriptions](api.md#clients-and-subscriptions). For Compose drain timing and
observed runner recovery delays, see [restart tests](development.md#runner-restart-and-recovery).
Graceful sleep/shutdown flush managed state, but killing the process can lose recent unsaved
changes; an action result is not an fsync guarantee.

## Ractors are not supported

Ractors can run Ruby in parallel under separate GVLs, but Rust thread safety does not establish
Ractor safety. The extension does not declare itself Ractor-safe; native objects are not
shareable. A direct native client call from a non-main Ractor raises `Ractor::UnsafeError`;
higher-level Ruby code may encounter isolation errors first. Creating a client in each Ractor
does not bypass this restriction, and `Ractor.make_shareable` does not make native handles usable
across Ractors.

Ruby 4's `Ractor::Port` and shareable Procs offer a possible future dispatcher basis, but requiring
Ruby 4 does not enable it. Actor definitions still contain ordinary blocks and mutable metadata;
callback ownership and native APIs need a separate Ractor-safety implementation.

Keep Rivet clients, registries, contexts, connections and subscriptions in the main Ractor.
Exchange plain data with computational Ractors, not Rivet objects or callback blocks.
For parallel Ruby actor hosting, use separate processes and initialize clients and runners
**after** forking; do not inherit an initialized Tokio runtime across a fork.
