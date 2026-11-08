# Ruby API

[README](../README.md) · [Development](development.md) · [SQLite](sqlite.md) · [Concurrency](concurrency.md)

The [counter](../examples/counter.rb) and [kitchen sink](../examples/kitchen_sink.rb) are runnable
examples. For method-level documentation, [generate YARD](development.md#yard-documentation).

## Actor API coverage

| Area | Ruby API |
| --- | --- |
| Identity | `ctx.id`, `name`, `key`, `region` |
| State | `ctx.state`, `state=`, `update_state` |
| Lifecycle | `on_create`, `on_start`, `on_sleep`, `on_destroy`; each receives `ctx` |
| Background work | `run { \|ctx\| ... }`, once per activation; `ctx.keep_awake { ... }` while busy |
| Connections | `create_conn_state(ctx, params)`, `on_before_connect(ctx, params)`, `on_connect(ctx, conn)`, `on_disconnect(ctx, conn)`, `on_subscribe(ctx, conn, event)` |
| Connection context | `ctx.connection`, `ctx.connections`; `conn.id`, `params`, `state`, `state=`, `emit(name, *args)`, `disconnect` |
| Events | `ctx.broadcast(name, *args)`, Ruby client subscriptions and unsubscribe |
| SQLite | `ctx.sql.execute(sql, *params)`, `query(sql, *params)`, `transaction { \|tx\| ... }`; see [SQLite](sqlite.md) |
| KV | `ctx.kv[key]`, `ctx.kv[key] = value`, `ctx.kv.delete(key)`; upstream-deprecated, backed by SQLite |
| Queues | `ctx.queue.send(name, body)`, `ctx.queue.next(*names, timeout:)`, `queue(:name) { \|ctx, body\| ... }` for client-sent messages |
| Queue clients | `handle.send_message(name, body)`, `send_and_wait(name, body, timeout:)` |
| Scheduling | `ctx.after(seconds, action, *args)`, `ctx.every(name, seconds, action, *args)`, `ctx.cancel_every(name)` |
| Shutdown | `ctx.sleep`, `ctx.destroy`, `ctx.aborted?`, `registry.stop`; see [shutdown](concurrency.md#shutdown-and-cancellation) |
| Raw HTTP | `on_fetch { \|ctx, request\| [status, headers, body_chunks] }`, `handle.fetch(path, method:, headers:, body:)` |
| S3 | Standard Ruby AWS SDK in actors; working Silo example and integration test |

Hooks use the class DSL, e.g. `on_start do |ctx| ... end`. Only declared actions are remotely
callable. Blocks run with the actor instance as `self`; instance variables are ephemeral per
activation. `on_start` runs on every activation, `on_create` only on initial creation.
`configure(sleep_timeout: 60, state_save_interval: 0.1)` uses seconds, like the rest of this API.
See [callback concurrency](concurrency.md#ordinary-ruby-threads) before sharing mutable data.

HTTP requests and responses are buffered. The response triple is Rack-shaped; this is not a
Rack server adapter and does not support streaming bodies or raw streaming WebSockets.

## Subclassing actors

Subclasses receive copies of the parent's action, queue, hook and configuration registrations,
and inherit its state initializer. Adding or replacing a registration on the child leaves
parents and siblings unchanged. These are snapshots taken when the subclass is created:
finish defining the base class before defining subclasses. Later DSL changes to the parent
do not reach existing subclasses.

`configure` preserves omitted settings, including inherited values. For example, if the parent
sets `state_save_interval: 7`, the child's `configure(sleep_timeout: 9)` retains that seven-second
save interval. With no previous setting, defaults remain 30 seconds for sleep and one second
for managed-state saves.

An action, queue handler or hook with the same name **replaces** the inherited block. Hooks do
not chain automatically, and `super` inside a DSL block cannot call the parent's block: these
registrations are not Ruby methods. Use ordinary instance methods for shared behaviour and
normal Ruby `super` calls:

```ruby
class BaseActor < Rivet::Actor
  on_start { |ctx| prepare(ctx) }

  def prepare(_ctx)
    @started_at = Time.now
  end
end

class Worker < BaseActor
  def prepare(ctx)
    super
    @jobs_processed = 0
  end
end
```

The inherited hook calls the child's `prepare`, which explicitly calls the parent method.
Ordinary methods are not remotely callable unless an `action` block exposes them.

Redefining `state` replaces the entire initializer; parent and child defaults are not merged.
Prefer `on_start` for activation setup. If you override `initialize`, it must take no required
arguments and call `super` so the actor's locks are allocated. Likewise, a custom class-level
`inherited` hook must call `super` to preserve DSL registration copying.

## Managed state

`state` receives `(ctx, input)`; absent input is `nil`. Constant defaults also work:
`state({"count" => 0})`. `ctx.state` is a **deeply frozen snapshot**. Use
`ctx.update_state { |state| ... }` or `ctx.state = value` to persist changes.

`update_state` returns the block result and writes the mutated value only if the block succeeds.
Keep these atomic update blocks short and do not perform I/O in them. `on_sleep` may update
state during cleanup. Rivet schedules saves: returning an action does **not** mean its state
has been fsynced. Graceful sleep and shutdown flush state; killing the process can lose recent
unsaved changes. Shutdown deadlines do not guarantee a final flush.

## Clients and subscriptions

Clients provide `get`, `get_or_create`, `create` and `get_for_id`; handles expose `id`.
Keys are Arrays of strings. Options include `params:`, `input:`, `pool:` and `region:` where
supported by Rust. See the [client example](../examples/client.rb).

Convenient action syntax (`handle.increment(3)`) remains available, but Ruby coercion and
pattern-matching protocols do not trigger remote calls. Use `handle.call(:to_ary)` or another
explicit name for actions that collide with Ruby methods or reserved coercion names.

`connection.on(:event) { |*args| ... }` delivers events on a Ruby listener thread. Without a
block, `subscription.poll(timeout:)` returns an argument Array or `nil` on timeout. An array-valued
event argument is preserved: `ctx.broadcast(:event, [1, 2])` delivers `[[1, 2]]` to `poll`.
Use either a listener block or polling, not both: they compete for events.

Call `subscription.unsubscribe` or `connection.close` when finished; block-form `connect` cleans
up on exit. Listener blocks must cooperate with shutdown: `unsubscribe(timeout: 30)` bounds the
listener join, and connection close shares its deadline across listeners. A timeout does not kill
a running block. See [resource ownership](concurrency.md#ordinary-ruby-threads).

### Timeouts and errors

`Client.new(timeout: 30)` sets the default total native-operation deadline. Override it on `call`,
`id`, eager `create`, `send_message`, `send_and_wait`, `fetch` or connection `close` with `timeout:`
(positive, finite seconds). Deadlines include discovery, requests and response bodies. `connect`
starts asynchronously; subscription polling has its own timeout. `send_and_wait(timeout: 0)` is
not supported; use `send_message` without waiting for a reply.

**Timeout is not proof that an action did not run.** The binding does not automatically retry
actions. Deadlines do not roll back remote actions or external side effects. Ruby `Timeout` and
`Thread#kill` are not substitutes for [native deadlines and cooperative cancellation](concurrency.md#gvl-and-native-io).

Native operation failures raise `Rivet::Error`; binding deadlines raise its `Rivet::TimeoutError`
subclass. Argument/conversion failures retain normal Ruby exception classes. Arbitrary Ruby
exceptions are logged locally and go through Rivet's normal error boundary; there is not yet a
complete structured/public application-error API.

### Historical cold-creation race

Engine **2.3.30** can return `actor/destroyed_during_creation` for concurrent cold `getOrCreate`
requests. Resolve a shared handle with `counter.id` before fan-out to multiple Ruby threads;
this caches its actor ID in Rust. Independent creating handles can still race. This is a
historical compatibility warning, not a claim of a reproduced 3.0.6 failure.

## Scheduling

`ctx.every(name, seconds, action, *args)` creates or updates an actor-scoped named interval
schedule with an interval of at least five seconds. Reusing a name replaces its action and
arguments, preserving cadence if the interval is unchanged. Missed ticks are skipped, not replayed.
`ctx.cancel_every(name)` returns whether it removed the schedule; it does not interrupt a
callback already running. These use Rust SDK durable scheduling and engine alarms, not Ruby timers.
`ctx.after(seconds, action, *args)` is one-shot and has no cancellation API.

There are no cron expressions, schedule listing or workflows. `keep_awake` only prevents local
idle sleep; it does not arrange recovery after a runner crash. The
[durable agent guide](../examples/durable_agent/README.md#client-api) explains its named recovery
alarm, installation ordering and unattended recovery limits on engine 3.0.6.

## Value conversion and transport

State, input, action arguments/results and event arguments use JSON-compatible values. The
native bridge converts Ruby values directly to/from Rust values without encoding/parsing JSON
strings. Supported values are nil, booleans, integers, finite floats, UTF-8-compatible strings,
symbols (converted to strings), arrays and hashes. Hash keys come back as strings.

Unsupported objects raise `TypeError`; `to_json` is not called. Convert dates, times and decimals
explicitly. Non-finite floats and cyclic or excessively nested values raise `ArgumentError`.
Integers outside −2⁶³ to 2⁶⁴−1 raise `RangeError`, including nested values; pass larger values as
decimal strings. TypeScript `number` has a narrower exact range (±(2⁵³−1)); the binding cannot
recover precision already lost by another client. [SQL binds](sqlite.md#queries-and-transactions)
use signed 64 bits only.

This describes the in-process Ruby–Rust boundary, not the wire protocol. The Rust SDK uses HTTP
for ordinary actions and WebSockets for connected actions/events, with versioned BARE binary
envelopes and CBOR payloads by default. The runner uses Rivet's separate binary WebSocket tunnel
to the engine. State and KV storage formats are unchanged; KV values remain stored as JSON bytes.

## SDK compatibility

The internal actor queue and the `queue` handler DSL are separate upstream APIs:
`ctx.queue.send` enqueues for manual consumption with `next`; client `send_message`/`send_and_wait`
dispatch a declared handler.

Actor state, connection state, queues and KV are deprecated in the TypeScript **3.0.6** SDK.
The Rust 3.0.6 high-level actor trait no longer has managed state or queue handlers; Ruby retains
them through core APIs. New code should favor SQLite for durable data, instance variables for
activation-local data, and actions plus SQLite for pending work. See the historical
[source-based audit](../RESEARCH.md#audit-2026-11-07) for coverage gaps and priorities.
Native API upgrades need protocol and lifecycle tests, not just a version bump.
