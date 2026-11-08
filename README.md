# Rivet for Ruby

Experimental Ruby actors and clients backed by the **real RivetKit Rust runtime**.
Not a Ruby imitation of the engine, and no Node.js process is needed to host Ruby actors.
Targets the WarpDrive-based **Rivet 3.0.6** engine, pinned by image digest.
`rivetkit` and `rivetkit-core` are pinned to **3.0.6**. The TypeScript interoperability client
remains at **2.3.30** to check compatibility with older clients.
See [RESEARCH.md](RESEARCH.md) for the design, upstream sources and tradeoffs.

## Examples

- [Counter actor](examples/counter.rb): managed state, actions and broadcast events.
- [Kitchen-sink actor](examples/kitchen_sink.rb): SQLite, queues, scheduling, connections and S3.
- [Example server](examples/server.rb) and [client](examples/client.rb): host both actors and call the counter.
- [Durable RubyLLM agent guide](examples/durable_agent/README.md), with its
  [actor](examples/durable_agent/agent.rb), [tools](examples/durable_agent/tools.rb),
  [server](examples/durable_agent/server.rb), [client](examples/durable_agent/client.rb) and
  [Compose setup](examples/durable_agent/compose.yaml).

## Run the whole stack

Requires Docker with Compose v2.24.4+ and BuildKit. The first native build takes several minutes.

```sh
docker compose up --build -d
docker compose --profile test run --rm test
```

This starts:

- Rivet 3.0.6 engine with a persistent `engine-preview-data` volume for WarpDrive's local log/cache,
  S3 object storage in `rivet-engine-preview`, and the `default` runner pool.
- A Ruby runner hosting the counter and kitchen-sink examples.
- [PGSTY Silo](https://github.com/pgsty/silo), pinned to `RELEASE.2026-10-26T00-00-00Z`, with a persistent volume and `rivet-local` bucket.
- A disposable test container that exercises the public Ruby API against those services.

Ports 6420 (Rivet), 9000 (S3), and 9001 (Silo console) bind to your machine's loopback interface.
The dev Rivet token is `dev`; Silo's local credentials are `rivetdev` / `rivetdev-local-password`.
**These settings are for local experiments, not production.**

**Engine storage and actor-owned blobs are separate.** WarpDrive manages Rivet state and SQLite
using its local log/cache and the `rivet-engine-preview` S3 bucket. The example independently uses
`aws-sdk-s3` to put/get objects in `rivet-local`; it does not access the engine bucket. The blob test
reads uploaded bytes directly through S3, sleeps the actor, and reads them through the reactivated actor.
Both buckets live in Silo's `s3-data` volume. Keep both volumes when restarting this single-node setup;
it is not a three-node replicated deployment or a test of disk-loss recovery.
The development engine config caps its local log at 1 GiB and its disk cache at 256 MiB rather than
auto-sizing them from host free space. Leave room for these plus Silo objects and Docker build caches.

This is a **3.x deployment, not a 2.x data migration**. The engine volume deliberately does not
reuse the old `engine-data` RocksDB volume. Existing 2.x data is left untouched but is not available
to this deployment. The volume and bucket retain their `preview` names so upgrading an existing
Compose stack does not create empty storage.

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

Requires **MRI Ruby 4.0+** with its development headers, Bundler, stable Rust (edition 2024), a C
compiler, libclang, and OpenSSL development headers. `.ruby-version` and Docker pin development to
Ruby 4.0.9. On Debian/Ubuntu the native-extension packages are
`build-essential libclang-dev libssl-dev pkg-config`; distro Ruby packages may be older than required.

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
Do not use `RIVETKIT_ENGINE_AUTO_DOWNLOAD=1` to test this setup: automatic engine selection
is separate from the explicitly pinned image and storage configuration here.
Signal handling belongs to Ruby; the example handles INT/TERM and calls `registry.stop`.

### Amp orbs

`.agents/setup` installs native build prerequisites, builds the Ruby version in `.ruby-version`
under `~/.local/share/rivet-ruby`, prepares stable Rust, installs the locked Ruby and TypeScript test
dependencies, and builds the debug extension with two Cargo jobs by default. The first Ruby/native
build takes several minutes; reruns reuse installed packages and build caches. A repository-scoped
login-shell hook selects this Ruby for later commands and services. Node.js and npm are provided by
the orb. Rivet and Silo are not started automatically; use Compose for integration tests.

### API documentation

Public Ruby classes, methods, callback signatures, and generated DSL methods have YARD documentation.
Native implementation classes and dispatcher helpers are marked private API, not supported entry points.

```sh
bundle exec rake yard
bundle exec yard stats --list-undoc
```

Generated HTML is in `doc/index.html`. The `.yardoc` database and generated HTML are not committed.

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
come back as strings. Ruby serialization rejects integers outside the native bridge's exact range
(−2⁶³ to 2⁶⁴−1) with `RangeError`, including nested values and custom `to_json` output. Pass larger
values as decimal strings. TypeScript `number` has a narrower exact-integer range (±(2⁵³−1)); the
binding cannot recover precision already lost by another client. SQL binds use signed 64 bits only.
`ctx.state` is a **deeply frozen snapshot**: use `ctx.update_state { |state| ... }`
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
Listener blocks must cooperate with shutdown: `unsubscribe(timeout: 30)` bounds the listener join,
and connection close shares its deadline across listeners. A timeout does not kill a running block.

Handles support `get`, `get_or_create`, `create`, `get_for_id`, and `id`.
Keys are Arrays of strings; options include `params:`, `input:`, `pool:` and `region:` where supported by Rust.
`Client.new(timeout: 30)` sets the default total native-operation deadline. Override it on `call`,
`id`, eager `create`, `send_message`, `send_and_wait`, `fetch`, or connection `close` with `timeout:`
(positive, finite seconds). Deadlines include discovery, requests and response bodies; `connect`
starts asynchronously, and subscription polling has its own timeout. `send_and_wait(timeout: 0)` is
not supported; use `send_message` without waiting for a reply. **Timeout is not proof that an action
did not run.** The binding does not automatically retry actions.

Convenient action syntax remains available, but Ruby coercion and pattern-matching protocols do
not trigger remote calls. Use `handle.call(:to_ary)` (or any other explicit name) for actions that
collide with Ruby methods or reserved coercion names.

Engine 2.3.30 can return `actor/destroyed_during_creation` for concurrent cold `getOrCreate` requests.
Resolve a shared handle with `counter.id` before fan-out to multiple Ruby threads. This caches its
actor ID in the Rust handle. Independent creating handles can still race.

## API coverage

| Area | Ruby API |
| --- | --- |
| Identity | `ctx.id`, `name`, `key`, `region` |
| State | `ctx.state`, `state=`, `update_state` |
| Lifecycle | `on_create`, `on_start`, `on_sleep`, `on_destroy`; each receives `ctx` |
| Background work | `run { |ctx| ... }`, once per activation; `ctx.keep_awake { ... }` while busy |
| Connections | `create_conn_state(ctx, params)`, `on_before_connect(ctx, params)`, `on_connect(ctx, conn)`, `on_disconnect(ctx, conn)`, `on_subscribe(ctx, conn, event)` |
| Connection context | `ctx.connection`, `ctx.connections`; `conn.id`, `params`, `state`, `state=`, `emit(name, *args)`, `disconnect` |
| Events | `ctx.broadcast(name, *args)`, Ruby client subscriptions and unsubscribe |
| SQLite | `ctx.sql.execute(sql, *params)`, `query(sql, *params)`, `transaction { |tx| ... }` |
| KV | `ctx.kv[key]`, `ctx.kv[key] = value`, `ctx.kv.delete(key)`; upstream-deprecated, backed by SQLite |
| Queues | `ctx.queue.send(name, body)`, `ctx.queue.next(*names, timeout:)`, `queue(:name) { |ctx, body| ... }` for client-sent messages |
| Queue clients | `handle.send_message(name, body)`, `send_and_wait(name, body, timeout:)` |
| Scheduling | `ctx.after(seconds, action, *args)`, `ctx.every(name, seconds, action, *args)`, `ctx.cancel_every(name)` |
| Shutdown | `ctx.sleep`, `ctx.destroy`, `ctx.aborted?`, `registry.stop` |
| Raw HTTP | `on_fetch { |ctx, request| [status, headers, body_chunks] }`, `handle.fetch(path, method:, headers:, body:)` |
| S3 | Standard Ruby AWS SDK in actors; working Silo example and integration test |

Hooks use the class DSL, e.g. `on_start do |ctx| ... end`. `on_start` runs on every activation;
`on_create` only runs when the actor is first created. `on_sleep` may update state during cleanup.
`configure(sleep_timeout: 60, state_save_interval: 0.1)` uses seconds, like the rest of this Ruby API.

### Durable RubyLLM agent example

[`examples/durable_agent`](examples/durable_agent/README.md) contains a server, client, tools and
Compose override for a SQLite-journaled text agent. It saves model messages and tool intents/results,
reuses completed steps, retries safe interrupted tools, and reports interrupted unsafe writes as
**outcome unknown** instead of replaying them. Request IDs deduplicate submissions; cancellation and
retry state persist. The background `run` hook keeps status/cancel actions available during model I/O.
On engine 3.0.6, a named recurring engine alarm resumes pending work after runner SIGKILL without
client polling. The schedule is installed before accepting work and removed when no work remains;
`keep_awake` alone only prevents local idle sleep. The model and tool crash tests exercise unattended
recovery while preserving committed results, unsafe-tool non-replay and local transaction rollback.
The example README explains crash boundaries and the limits relative to Pi Durable; this is not
exactly-once external execution or a full Pi framework port. RubyLLM is optional, not a runtime gem dependency.

`ctx.every` creates or updates an actor-scoped named interval schedule (at least five seconds).
Reusing a name replaces its action and arguments, preserving the cadence if the interval is unchanged.
Missed ticks are skipped, not replayed. `ctx.cancel_every` returns whether it removed the schedule;
it does not interrupt a callback already running. These use the Rust SDK's durable scheduling and
engine alarms, not Ruby timer threads. One-shot `ctx.after` schedules still have no cancellation API.

### SQLite and compatibility APIs

SQLite `query` returns Arrays of row Hashes. `execute` returns `columns`, `rows`, `changes` and
`last_insert_row_id`. Bind nil, booleans (0/1), signed 64-bit integers, floats, UTF-8 text and binary
Strings (`string.b`, SQLite BLOBs). Out-of-range Ruby integer binds raise `RangeError` before native
conversion. Results preserve binary Strings. Transactions commit on normal
block completion and roll back on exceptions or nonlocal exits. Use the yielded `tx`, not `ctx.sql`,
inside a transaction. This API buffers HTTP requests/responses and uses a Rack-shaped response triple;
it is not a Rack server adapter and does not support streaming bodies.

The internal actor queue and the `queue` handler DSL are separate upstream APIs: `ctx.queue.send`
enqueues for manual consumption with `next`; client `send_message`/`send_and_wait` dispatch a declared handler.
Actor state, connection state, queues and KV are deprecated in the TypeScript 3.0.6 SDK. The Rust
3.0.6 high-level actor trait no longer has managed state or queue handlers; Ruby retains them through
core APIs. New code should favor SQLite for durable data, instance variables for activation-local
data, and actions plus SQLite for pending work. See the [source-based audit](RESEARCH.md#audit-2026-11-07)
for coverage gaps and priorities.

### SQLite extensions and data types

The current binding uses Rivet's remote SQLite backend: SQL executes in the engine, not against a
local database in the Ruby runner. Extension availability therefore depends on the engine build and
connection settings, not on gems installed alongside the runner.

The following were probed through the Ruby binding against the previous Compose engine
(`3.0.0-preview.2`) on 2026-11-07, which reported SQLite **3.46.0**. These are observations of that
image, not guarantees for other Rivet deployments or future versions.

| Feature | Observed support |
| --- | --- |
| JSON functions | `json_extract` works |
| SQLite JSONB | `jsonb` works and produces a BLOB, not a Ruby Hash |
| FTS5 full-text search | Virtual table creation, insertion and `MATCH` query work |
| R*Tree spatial index | Virtual table creation works |
| Runtime extension loading | `load_extension(...)` fails with `not authorized`, despite the build reporting `ENABLE_LOAD_EXTENSION` |
| sqlite-vec | `vec_version()` is unavailable |
| SpatiaLite | `spatialite_version()` is unavailable |
| Optional math functions | `sqrt()` is unavailable |

Installing a SQLite extension gem in the Ruby runner does not load it into the engine. Custom
native extensions would need engine-side integration and initialization; the binding exposes no
extension-loading controls, Ruby-defined SQL functions, or custom collation registration.

SQLite stores NULL, INTEGER, REAL, TEXT and BLOB values. Column declarations such as `DECIMAL`,
`TIMESTAMP`, `JSON` or `UUID` do not create dedicated storage types. In the probe, a decimal string
inserted into a `DECIMAL(20,6)` column became a floating-point REAL; timestamp, JSON and UUID strings
remained TEXT. The wrapper does not automatically convert results into `BigDecimal`, `Time`, parsed
JSON, or UUID objects.

| Application value | Suggested representation |
| --- | --- |
| Money or exact decimals | Scaled signed 64-bit integers, or decimal strings in TEXT; SQLite REAL arithmetic is not exact decimal arithmetic |
| Dates and times | ISO 8601 TEXT or integer timestamps, with an application-defined timezone and precision |
| UUIDs | TEXT or 16-byte BLOBs |
| JSON documents | JSON TEXT with explicit Ruby serialization/parsing, or SQLite JSONB as an opaque BLOB |
| Vectors | Packed BLOBs can store values, but do not provide vector indexing or similarity functions |

BLOB results are binary Ruby Strings inside the actor. Encode arbitrary binary data as Base64 or
byte arrays before returning it through JSON actions.

There is no Sequel adapter yet. Sequel's standard SQLite adapter opens a local database through the
`sqlite3` gem and cannot be pointed at `ctx.sql` unchanged. A future Rivet adapter could provide
query-building, schema and Ruby type-conversion APIs, scoped to an actor's database. It would not
enable missing engine extensions or make SQLite decimal arithmetic exact.

## Tests and interoperability

Buildkite runs [the CI pipeline](https://buildkite.com/catkins-test/rivet-rb) on the hosted Linux
queue, following the same mise setup as `slatedb-rb`. `.mise.toml` pins Ruby, Rust and Node;
`.buildkite/hooks/post-checkout` installs native build libraries before mise installs Ruby.

`.buildkite/cache.yml` defines Buildkite Cache entries for installed Bundler gems and npm downloads.
Keys include the platform, Ruby/toolchain config and lockfiles;
lockfile changes can restore an older dependency cache before the package manager reconciles it.
The dedicated `rivet-rb` registry allows only this pipeline's `main` builds to save entries, while
other branches can restore from `main`. The cluster's shared default registry is unchanged.
Hosted cache volumes retain `/mise` toolchains, the Cargo registry at `/mise/rivet-rb-cargo`, and
`target` build intermediates without archiving the large Rust build directory. Cargo's home stays
at the same absolute path across jobs so dependency fingerprints do not reference deleted checkouts.
Cargo still checks source, toolchain and build configuration changes before reusing compiled crates.
Both caches are optional accelerators: misses rebuild normally,
and compile, lint, docs and tests always run. Test results, logs and engine/Silo data are not cached.

On a Linux machine with Docker, the same checks run with `mise run ci`. This compiles the extension,
runs rustfmt and Clippy, renders YARD and requires 100% documentation coverage, then runs the full
Ruby suite against real Rivet/Silo services and the TypeScript interoperability client. Skipped tests
fail CI. The durable-agent tests use a local model fixture, not a paid provider.

CI uses a separate Compose project with disposable volumes and the Linux host-network override.
It needs ports 6420, 9000 and 9001 free; stop your development stack first without deleting its
volumes. CI captures runner/service logs under `tmp/ci-logs` and removes only its own containers
and volumes on exit. Buildkite uploads those logs as artifacts, including on test failure.

The integration suite covers Unicode/nested JSON, explicit action allowlists, identity/input,
concurrent updates, SQL types/commit/rollback, KV deletion, WebSocket events, connection state,
unsubscribe, queues, schedules, binary HTTP, and persisted state/SQL/KV/S3 after sleep/wake.
`bundle exec rake test` also checks stalled-response deadlines, integer rejection and coercions;
with `RIVET_ENDPOINT`, it creates an isolated test pool for activation isolation, overload, reserved
lifecycle capacity and bounded shutdown. Run this suite against the local development stack.
For a host runner, export `RIVET_ENDPOINT` and run `bundle exec ruby -Itest test/integration_test.rb`.
S3 tests additionally require `S3_ENDPOINT`, `S3_BUCKET`, and AWS credentials (Compose supplies them).

With the Compose stack running, test an active actor across a runner restart:

```sh
bash test/runner_restart.sh
# With the orb host-network override:
bash test/runner_restart.sh -f compose.yaml -f docker/compose.host.yaml
```

This restarts the runner, checks the same actor ID with a new activation, and verifies persisted
state, SQLite, KV, and a new WebSocket subscription. It interrupts existing runner connections.
The engine can take over 40 seconds to release an active actor from the old runner; requests
during recovery can hit client or gateway deadlines. The test retries only read-only `info` probes
with a bounded recovery window, not mutations. Compose allows 45 seconds for runner shutdown
because the SDK's advertised drain deadline is 30 seconds; the old 10-second grace period killed it.
This is eventual recovery, not uninterrupted service or a guarantee about unsaved state on SIGKILL.

The optional interoperability test uses the actual TypeScript 2.3.30 client against Ruby actors:

```sh
npm ci --prefix test/interop
RIVET_ENDPOINT=http://127.0.0.1:6420 RIVET_TOKEN=dev npm test --prefix test/interop
```

## Thread safety, the GVL, and Ractors

### Ordinary Ruby threads

Use this binding from ordinary Ruby threads in the **main Ractor**. Clients and actor handles can
issue native requests from multiple threads. Resolve a shared creating handle before fan-out as
described above. This does not make every resource or application object safe for concurrent mutation:

- Actions, client queue handlers, and HTTP handlers share an action mutex per actor instance.
  They run one at a time within that instance, even when a handler releases the GVL for I/O.
  Different actors can make progress concurrently; execution order is not guaranteed.
  Avoid synchronous self-calls and cyclic actor-to-actor calls.
- Lifecycle, connection and background `run` hooks do not take that action mutex and can overlap work handlers.
  Use `ctx.update_state` for atomic actor-state updates, keep its block short and free of I/O,
  and use your own synchronization for instance variables shared between hooks and actions.
- Start a registry once at a time. Another Ruby thread can call `registry.stop`; callbacks must
  cooperate with cancellation and shutdown as described below.
- Give connections, subscriptions, and SQL transactions one owner, or coordinate their use yourself.
  Do not race `on` with `close`, close a resource another thread is using, or share a transaction
  between independent operations. Use either a subscription listener block or manual polling;
  combining them makes the two consumers compete for events. Listener blocks run on Ruby threads,
  so synchronize any application data they share with other threads.

### GVL and native I/O

The extension releases MRI's Global VM Lock (GVL) while waiting for native client requests, SQL,
queue operations, and callback/event polling. Rust's shared multi-threaded Tokio runtime can keep
working while other Ruby threads run. Ruby argument conversion happens before releasing the GVL;
Ruby result conversion and exception creation happen after it is reacquired. Tokio worker threads
do not call Ruby: actor callbacks are sent through channels and executed by Ruby-created threads.

This enables overlapping I/O, **not parallel CPU-heavy Ruby execution within one Ractor**. The
callback worker limits are admission limits, not a number of Ruby CPU cores. Ruby-side JSON conversion
and other Ruby code still use the GVL. There is no Fiber scheduler integration. Releasing the GVL is
also not cancellation: the native wrapper supplies no unblock function, so do not rely on Ruby
`Timeout` or `Thread#kill` to cancel native I/O. Use the binding's operation deadlines and cooperative
callback cancellation; neither rolls back remote actions or external side effects.

### Ractors are not supported

Ractors can execute Ruby in parallel under separate GVLs, but Rust thread safety does not establish
Ractor safety. This extension does not declare itself Ractor-safe, and its native objects are not
shareable. A direct native client call from a non-main Ractor raises `Ractor::UnsafeError`;
higher-level Ruby code can encounter isolation errors first. Creating a separate client inside
each Ractor does not bypass the extension restriction, and `Ractor.make_shareable` does not make
native handles usable across Ractors.

Ruby 4's `Ractor::Port` and shareable Procs offer a better basis for a future Ractor dispatcher,
but requiring Ruby 4 does not enable it. Our actor definitions still contain ordinary blocks and
mutable metadata; callback ownership and native APIs need a separate Ractor-safety implementation.

Keep all Rivet clients, registries, contexts, connections, and subscriptions in the main Ractor.
If your application uses Ractors for computation, exchange plain data with them rather than Rivet
objects or callback blocks. For parallel Ruby actor hosting, use separate processes and initialize
clients and runners **after** forking; do not inherit an initialized Tokio runtime across a fork.

## Experimental limits

- MRI only; other Ruby implementations are not supported.
- `registry.start(workers: 16, lifecycle_workers: 4, background_workers: 16,
  shutdown_timeout: 45)` caps live work, lifecycle and background threads separately. Background
  hooks share the work channel; the work and lifecycle channels each hold at most 64 pending
  callbacks. Excess work fails with Rivet's overload error rather
  than allocating more threads; waiting for an actor's action lock also consumes a work slot.
  Lifecycle capacity is reserved but finite, not a guarantee that hooks cannot overload. These are
  bridge admission limits, not a bound on upstream runtime memory or buffered HTTP bodies.
- Cancellation cannot forcibly interrupt Ruby code or external side effects. Use `ctx.aborted?` for
  cooperative cancellation; stale callbacks cannot use `update_state` after their native reply closes.
  `stop` requests shutdown; `start` keeps dispatching cleanup until completion or the shutdown deadline,
  then cancels replies and aborts the runner task. If it times out it raises `Rivet::TimeoutError`;
  it does not kill Ruby threads, guarantee final persistence, or permit restart while callbacks live.
  Deadlines require MRI to schedule the dispatcher; native extensions that retain the GVL can delay it.
- No workflows, cron expressions, schedule listing or one-shot cancellation, raw streaming
  WebSockets, hibernation callbacks, serverless HTTP hosting, schema generation, or Fiber scheduler
  integration yet. Named interval schedules can be cancelled with `ctx.cancel_every`.
- Native operation failures raise `Rivet::Error`; binding deadlines raise its `Rivet::TimeoutError` subclass.
  Ruby argument/serialization failures retain their normal exception classes.
  Arbitrary Ruby exceptions are logged locally and go through Rivet's normal error boundary; this is
  not yet a complete structured/public application-error API.
- Native APIs are pinned. Upgrades need protocol and lifecycle tests, not just a version bump.

MIT-licensed Ruby binding. Rivet's Rust crates have their own Apache-2.0 licenses; the separately
run Silo service is AGPL-3.0. Nothing has been published to RubyGems.
