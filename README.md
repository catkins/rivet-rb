# Rivet for Ruby

Experimental Ruby actors and clients backed by the **real RivetKit Rust runtime**.
Not a Ruby imitation of the engine, and no Node.js process is needed to host Ruby actors.
Pins `rivetkit`, `rivetkit-core`, the engine and the interoperability tests to **2.3.30**.
See [RESEARCH.md](RESEARCH.md) for the design, upstream sources and tradeoffs.

## Run the whole stack

Requires Docker with Compose v2.24.4+ and BuildKit. The first native build takes several minutes.

```sh
docker compose up --build -d
docker compose --profile test run --rm test
```

This starts:

- Rivet engine with a persistent `engine-data` volume and the `default` runner pool.
- A Ruby runner hosting the counter and kitchen-sink examples.
- [PGSTY Silo](https://github.com/pgsty/silo), pinned to `RELEASE.2026-10-26T00-00-00Z`, with a persistent volume and `rivet-local` bucket.
- A disposable test container that exercises the public Ruby API against those services.

Ports 6420 (Rivet), 9000 (S3), and 9001 (Silo console) bind to your machine's loopback interface.
The dev Rivet token is `dev`; Silo's local credentials are `rivetdev` / `rivetdev-local-password`.
**These settings are for local experiments, not production.**

**S3 is for actor-owned blobs, not Rivet's internal state.** Engine 2.3.30 has no S3 storage backend.
The example uses `aws-sdk-s3` to put/get Silo objects. The test independently reads the uploaded
bytes through S3, sleeps the actor, and reads the same object through the reactivated actor.
Rivet's state, queues, schedules and SQLite data live in the engine volume.

```sh
docker compose logs -f runner
docker compose down       # retain data
docker compose down -v    # delete this experiment's data
```

If an orb cannot forward Docker bridge traffic, use the supplied Linux host-network override:

```sh
docker build --network host --allow network.host -t rivet-rb:local .
docker compose -f compose.yaml -f docker/compose.host.yaml up --no-build -d
docker compose -f compose.yaml -f docker/compose.host.yaml --profile test run --rm test
```

The override is for a trusted development host only: host networking bypasses loopback-only port mappings.

## Build without Docker

Requires MRI Ruby 3.1+, Bundler, stable Rust (edition 2024), a C compiler, libclang, and OpenSSL development headers.
On Debian/Ubuntu the system packages are `ruby-dev build-essential libclang-dev libssl-dev pkg-config`.

```sh
bundle install
RB_SYS_CARGO_PROFILE=dev bundle exec rake compile
bundle exec ruby -Itest test/actor_test.rb
```

Omit `RB_SYS_CARGO_PROFILE=dev` for an optimized native extension. `bundle exec rake` builds and runs
all Ruby tests; integration tests skip unless `RIVET_ENDPOINT` is set. This is a source gem; no
precompiled platform gems are published.

To use an existing engine, set `RIVET_ENDPOINT`, `RIVET_TOKEN`, `RIVET_NAMESPACE`,
`RIVET_POOL_NAME` and `RIVETKIT_ENGINE_SPAWN=never`, then run `bundle exec ruby examples/server.rb`.
The pool must already exist, as configured by `docker/init-engine.sh` in the Compose setup.
For Rivet's automatic local-engine download, use `RIVETKIT_ENGINE_AUTO_DOWNLOAD=1` instead.
Signal handling belongs to Ruby; the example handles INT/TERM and calls `registry.stop`.

## Server example: define and host an actor

The server defines a persistent counter, exposes two actions, and broadcasts changes to connected
clients. The same actor is in [`examples/counter.rb`](examples/counter.rb);
[`examples/server.rb`](examples/server.rb) hosts it alongside the kitchen-sink actor.

```ruby
require "rivet"

class Counter < Rivet::Actor
  state { |_ctx, input| {"count" => input&.fetch("count", 0) || 0} }

  action :increment do |ctx, amount = 1|
    count = ctx.update_state { |state| state["count"] += amount }
    ctx.broadcast(:newCount, count)
    count
  end

  action :count do |ctx|
    ctx.state.fetch("count")
  end
end

registry = Rivet::Registry.new(counter: Counter)
Signal.trap("INT") { registry.stop }
Signal.trap("TERM") { registry.stop }
registry.start(pool: ENV.fetch("RIVET_POOL_NAME", "default"))
```

`docker compose up --build -d` already runs the example server. If you run the server outside Docker
instead, stop the Compose runner first, then use the engine started by Compose:

```sh
docker compose stop runner
RIVET_ENDPOINT=http://127.0.0.1:6420 RIVET_TOKEN=dev RIVET_POOL_NAME=default \
  RIVETKIT_ENGINE_SPAWN=never bundle exec ruby examples/server.rb
```

Only explicitly declared actions are remotely callable. Blocks run with the actor instance as
`self`, so instance variables are ephemeral per activation. `state` receives `(ctx, input)`;
`input` is `nil` when absent. Constant defaults also work: `state({"count" => 0})`.

State, input, action arguments/results and event arguments use JSON-compatible values. Hash keys
come back as strings. `ctx.state` is a **deeply frozen snapshot**: use `ctx.update_state { |state| ... }`
or `ctx.state = value` to persist changes. `update_state` returns the block result and writes the
mutated value only if the block succeeds. Keep these blocks short and do not perform I/O in them.
Rivet schedules saves; returning an action does not mean its state has been fsynced. Graceful sleep
and shutdown flush state; killing the process can lose recent unsaved changes.

## Client example: call the actor and receive events

Run [`examples/client.rb`](examples/client.rb) in another terminal. Each run creates a fresh counter,
so the output below is repeatable:

```sh
bundle exec ruby -Ilib examples/client.rb
# Or, without installing Ruby/Rust on your host, while the Compose runner is running:
docker compose exec runner bundle exec ruby -Ilib examples/client.rb
```

```ruby
require "rivet"
require "securerandom"

client = Rivet::Client.new(
  ENV.fetch("RIVET_ENDPOINT", "http://127.0.0.1:6420"),
  token: ENV.fetch("RIVET_TOKEN", "dev"),
  pool: ENV.fetch("RIVET_POOL_NAME", "default")
)
counter = client.get_or_create(:counter, ["example", SecureRandom.hex(8)], input: {count: 10})
puts counter.increment(3) # => 13, stateless HTTP action
puts counter.call(:increment, 2, timeout: 5) # => 15, explicit action name and deadline

counter.connect do |connection|
  subscription = connection.on(:newCount)
  puts connection.increment(4) # => 19, WebSocket action
  p subscription.poll(timeout: 3) # => [19], positional event arguments
end # closes the connection and unsubscribes
```

`connection.on(:event) { |*args| ... }` delivers events on a Ruby listener thread.
Without a block, `poll(timeout:)` returns an argument Array, or `nil` on timeout.
Call `subscription.unsubscribe` or `connection.close` when finished.
An array-valued event argument is preserved: `ctx.broadcast(:event, [1, 2])` delivers `[[1, 2]]` to `poll`.

Handles support `get`, `get_or_create`, `create`, `get_for_id`, and `id`.
Keys are Arrays of strings; options include `params:`, `input:`, `pool:` and `region:` where supported by Rust.
Actions default to a 30-second client deadline. **Timeout is not proof that an action did not run.**
The binding does not automatically retry actions.

Engine 2.3.30 can return `actor/destroyed_during_creation` for concurrent cold `getOrCreate` requests.
Resolve a shared handle with `counter.id` before fan-out to multiple Ruby threads. This caches its
actor ID in the Rust handle. Independent creating handles can still race.

## API coverage

| Area | Ruby API |
| --- | --- |
| Identity | `ctx.id`, `name`, `key`, `region` |
| State | `ctx.state`, `state=`, `update_state` |
| Lifecycle | `on_create`, `on_start`, `on_sleep`, `on_destroy`; each receives `ctx` |
| Connections | `create_conn_state(ctx, params)`, `on_before_connect(ctx, params)`, `on_connect(ctx, conn)`, `on_disconnect(ctx, conn)`, `on_subscribe(ctx, conn, event)` |
| Connection context | `ctx.connection`, `ctx.connections`; `conn.id`, `params`, `state`, `state=`, `emit(name, *args)`, `disconnect` |
| Events | `ctx.broadcast(name, *args)`, Ruby client subscriptions and unsubscribe |
| SQLite | `ctx.sql.execute(sql, *params)`, `query(sql, *params)`, `transaction { |tx| ... }` |
| KV | `ctx.kv[key]`, `ctx.kv[key] = value`, `ctx.kv.delete(key)`; upstream-deprecated, backed by SQLite |
| Queues | `ctx.queue.send(name, body)`, `ctx.queue.next(*names, timeout:)`, `queue(:name) { |ctx, body| ... }` for client-sent messages |
| Queue clients | `handle.send_message(name, body)`, `send_and_wait(name, body, timeout:)` |
| Scheduling | `ctx.after(seconds, action, *args)` |
| Shutdown | `ctx.sleep`, `ctx.destroy`, `ctx.aborted?`, `registry.stop` |
| Raw HTTP | `on_fetch { |ctx, request| [status, headers, body_chunks] }`, `handle.fetch(path, method:, headers:, body:)` |
| S3 | Standard Ruby AWS SDK in actors; working Silo example and integration test |

Hooks use the class DSL, e.g. `on_start do |ctx| ... end`. `on_start` runs on every activation;
`on_create` only runs when the actor is first created. `on_sleep` may update state during cleanup.
`configure(sleep_timeout: 60, state_save_interval: 0.1)` uses seconds, like the rest of this Ruby API.

SQLite `query` returns Arrays of row Hashes. `execute` returns `columns`, `rows`, `changes` and
`last_insert_row_id`. Bind nil, booleans (0/1), signed 64-bit integers, floats, UTF-8 text and binary
Strings (`string.b`, SQLite BLOBs). Results preserve binary Strings. Transactions commit on normal
block completion and roll back on exceptions or nonlocal exits. Use the yielded `tx`, not `ctx.sql`,
inside a transaction. This API buffers HTTP requests/responses and uses a Rack-shaped response triple;
it is not a Rack server adapter and does not support streaming bodies.

The internal actor queue and the `queue` handler DSL are separate upstream APIs: `ctx.queue.send`
enqueues for manual consumption with `next`; client `send_message`/`send_and_wait` dispatch a declared handler.

## Tests and interoperability

The integration suite covers Unicode/nested JSON, explicit action allowlists, identity/input,
concurrent updates, SQL types/commit/rollback, KV deletion, WebSocket events, connection state,
unsubscribe, queues, schedules, binary HTTP, and persisted state/SQL/KV/S3 after sleep/wake.
For a host runner, export `RIVET_ENDPOINT` and run `bundle exec ruby -Itest test/integration_test.rb`.
S3 tests additionally require `S3_ENDPOINT`, `S3_BUCKET`, and AWS credentials (Compose supplies them).

The optional interoperability test uses the actual TypeScript 2.3.30 client against Ruby actors:

```sh
npm ci --prefix test/interop
RIVET_ENDPOINT=http://127.0.0.1:6420 RIVET_TOKEN=dev npm test --prefix test/interop
```

## Experimental limits

- MRI only. Start clients/runners **after** forking. The Tokio runtime must not be inherited across a fork.
- Actions and client queue handlers are mutually exclusive within one Ruby actor instance; different
  actors can progress concurrently. Scheduling order is not promised. Avoid synchronous self-calls
  and cyclic actor-to-actor calls. Lifecycle callbacks are managed separately by Rivet.
- Callbacks execute on Ruby-created threads, never Tokio workers. Blocking native I/O releases the GVL.
  CPU-heavy Ruby still shares MRI's GVL. One worker is created per callback; there is no bounded Ruby worker pool yet.
- Cancellation cannot forcibly interrupt Ruby code or external side effects. Use `ctx.aborted?` for
  cooperative cancellation; stale callbacks cannot use `update_state` after their native reply closes.
- No workflows, cron management, schedule cancellation/listing, raw streaming WebSockets, hibernation
  callbacks, serverless HTTP hosting, schema generation, or Fiber scheduler integration yet.
- Errors from native operations are runtime exceptions; action failures become `Rivet::Error`.
  Arbitrary Ruby exceptions are logged locally and go through Rivet's normal error boundary; this is
  not yet a complete structured/public application-error API.
- Native APIs are pinned. Upgrades need protocol and lifecycle tests, not just a version bump.

MIT-licensed Ruby binding. Rivet's Rust crates have their own Apache-2.0 licenses; the separately
run Silo service is AGPL-3.0. Nothing has been published to RubyGems.
