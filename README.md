# Rivet for Ruby

Experimental Ruby actors and clients backed by the **real RivetKit Rust runtime**.
No Node.js process is needed to host Ruby actors.
Targets the WarpDrive-based **Rivet 3.0.6** engine, pinned by image digest;
`rivetkit`, `rivetkit-core` and the TypeScript interoperability client are also **3.0.6**.

Requires **MRI Ruby 4.0+**. Docker is the simplest way to try the stack; a source build also
needs Rust and native build tools. No precompiled platform gems are published, and nothing
has been published to RubyGems. This is an experiment, not a production durability or HA guarantee.

## Examples

- [Counter](examples/counter.rb): managed state, actions and broadcast events.
- [Kitchen sink](examples/kitchen_sink.rb): SQLite, queues, scheduling, connections and S3.
- [Server](examples/server.rb): host both actors.
- [Client](examples/client.rb): call the counter and receive events.
- [Durable RubyLLM agent guide](examples/durable_agent/README.md): a SQLite-journaled text agent,
  with its [actor](examples/durable_agent/agent.rb), [tools](examples/durable_agent/tools.rb),
  [server](examples/durable_agent/server.rb), [client](examples/durable_agent/client.rb) and
  [Compose setup](examples/durable_agent/compose.yaml). Covers crash recovery, unsafe-tool
  non-replay and cancellation; it does **not** promise exactly-once external execution.

## Docker quickstart

Requires Docker with Compose v2.24.4+ and BuildKit. The first native build takes several minutes.
Run from the repository root:

```sh
docker compose up --build -d
docker compose --profile test run --rm test
docker compose exec runner bundle exec ruby -Ilib examples/client.rb
```

This starts the pinned Rivet engine, a Ruby runner hosting the counter and kitchen-sink actors,
and [PGSTY Silo](https://github.com/pgsty/silo) object storage. The test container is disposable.
Ports 6420 (Rivet), 9000 (S3), and 9001 (Silo console) bind to your machine's loopback interface.
The dev Rivet token is `dev`; Silo's credentials are `rivetdev` / `rivetdev-local-password`.
**These credentials and settings are for local experiments, not production.**

```sh
docker compose logs -f runner
docker compose down       # stop without deleting volumes
```

**Keep the engine and Silo volumes.** `docker compose down -v` deletes this experiment's data.
Engine state/SQLite and actor-owned S3 blobs use separate buckets. This single-node stack is
not a disk-loss recovery test. It is a **3.x deployment, not a 2.x migration**: old `engine-data`
is untouched but unavailable here. The `engine-preview-data` volume and `rivet-engine-preview`
bucket deliberately retain their names to avoid creating empty storage on upgrade.
See [storage and restart details](docs/development.md#storage-and-restarts).

If an orb cannot forward Docker bridge traffic, use the
[Linux host-network workaround](docs/development.md#host-network-workaround).
It bypasses loopback-only port mappings and is for trusted development hosts only.

## Define and host an actor

The [example server](examples/server.rb) already runs in Compose. A minimal actor looks like this:

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

Only explicitly declared actions are remotely callable. Blocks run with the actor instance as
`self`; instance variables last only for that activation. `state` receives `(ctx, input)`, with
`nil` input when absent. `ctx.state` is a **deeply frozen snapshot**; use `update_state` or
`state=` to persist changes. Keep update blocks short and free of I/O.

**An action returning does not mean its state has been fsynced.** Graceful sleep and shutdown
flush state; killing the process can lose recent unsaved changes. Managed state and queues are
compatibility APIs; prefer [SQLite](docs/sqlite.md) for new durable data models.

To run outside Docker, follow [build and engine configuration](docs/development.md#build-without-docker).
Stop the Compose runner first so different actor registrations do not share its pool.

## Call the actor and receive events

The [example client](examples/client.rb) creates a fresh counter each run:

```ruby
require "rivet"
require "securerandom"

client = Rivet::Client.new(
  ENV.fetch("RIVET_ENDPOINT", "http://127.0.0.1:6420"),
  token: ENV.fetch("RIVET_TOKEN", "dev"),
  pool: ENV.fetch("RIVET_POOL_NAME", "default")
)
counter = client.get_or_create(:counter, ["example", SecureRandom.hex(8)], input: {count: 10})
puts counter.increment(3) # => 13, HTTP action
puts counter.call(:increment, 2, timeout: 5) # => 15, explicit name and deadline

counter.connect do |connection|
  subscription = connection.on(:newCount)
  puts connection.increment(4) # => 19, WebSocket action
  p subscription.poll(timeout: 3) # => [19], positional event arguments
end # closes the connection and unsubscribes
```

Run it locally with `bundle exec ruby -Ilib examples/client.rb`, or use the Compose command above.
Clients and actor handles support ordinary Ruby threads in the **main Ractor**.
Use operation deadlines rather than Ruby `Timeout` to bound native I/O.
**A timeout is not proof that an action did not run; actions are not automatically retried.**
See [clients, subscriptions and timeouts](docs/api.md#clients-and-subscriptions).

## Guides

- [API](docs/api.md): actor hooks, state, clients, deadlines, scheduling, value conversion
  and SDK compatibility.
- [SQLite](docs/sqlite.md): transactions, binary values, measured engine extensions,
  application types and Sequel limitations.
- [Concurrency](docs/concurrency.md): action serialization, GVL behavior, callback admission,
  cooperative shutdown and unsupported Ractors.
- [Development](docs/development.md): storage, host-network setup, source builds, Amp orbs,
  YARD, tests, interoperability and CI caches.
- [Durable agent](examples/durable_agent/README.md): setup, recovery boundaries and crash tests.
- [Historical research](RESEARCH.md): design, upstream sources, tradeoffs and source-based audits.

## Experimental limits

- MRI only; no Ractor support or Fiber scheduler integration. Parallel CPU-heavy Ruby hosting
  needs separate processes, initialized after forking.
- Per-actor actions are serialized, but lifecycle, connection and background hooks can overlap
  them. Callback capacity is bounded; overload fails rather than creating unlimited threads.
- Cancellation and shutdown are cooperative. A deadline cannot kill Ruby code, undo external
  effects or guarantee final persistence. See [shutdown limits](docs/concurrency.md#shutdown-and-cancellation).
- No workflows, cron expressions, schedule listing, one-shot schedule cancellation, raw streaming
  WebSockets, hibernation callbacks, serverless HTTP hosting or schema generation. HTTP bodies
  are buffered; the response triple is Rack-shaped, not a Rack server adapter.
- Native failures raise `Rivet::Error`; deadlines raise `Rivet::TimeoutError`. Arbitrary Ruby
  exceptions cross Rivet's normal error boundary, not a complete structured/public application-error API.
- Native APIs are pinned. Upgrades need protocol and lifecycle tests, not just a version bump.

MIT-licensed Ruby binding. Rivet's Rust crates have their own Apache-2.0 licenses;
the separately run Silo service is AGPL-3.0.
