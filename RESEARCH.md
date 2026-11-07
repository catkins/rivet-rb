# Research: Ruby bindings for Rivet actors

Investigated 2026-10-27. Outcome: **the Rust route works**. Host Ruby callbacks on Ruby-owned
threads and use the existing Rust actor runner, rather than reimplementing the runner/backend protocol.

## Sources and version choice

- [Rust quickstart](https://rivet.dev/actors/docs/quickstart/rust/): public `Actor`, `Handles`, `Ctx`, registry and client APIs.
- [Rivet source inspected](https://github.com/rivet-dev/rivet/tree/80ee8b8c22b81e2b1c641996740cde937bc89300): stable 2.3.30 workspace.
- [Stable release source](https://github.com/rivet-dev/rivet/tree/a7f753c2896e94cda59e95024f995ca2bf8f3170).
- [CEL Ruby binding](https://github.com/buildkite/cel-rs-rb): small Magnus `cdylib`, `rb_sys` extension configuration and rake-compiler layout.
- [SlateDB Ruby binding](https://github.com/catkins/slatedb-rb): Ruby keyword/block wrappers, shared Tokio runtime and no-GVL waits around native I/O.
- [Silo](https://github.com/pgsty/silo): local S3-compatible object storage and bundled `mcli` (`mc` alias).

The original implementation pinned **2.3.30**. Its packaged source matched all checked `src/`
files for `rivetkit` (16), `rivetkit-core` (63), and `rivetkit-client` (16). A later comparison
found that the top-level `3.0.0-preview.2` API was essentially unchanged; most apparent differences
were omitted tests, while runtime changes were in core.
The published crate's repository metadata names `rivet-ee`, but its packaged SDK source is inspectable
and matched the public monorepo. Use published packages; no Git checkout or Rivet fork is required to build.

The Rust dependencies now pin **3.0.6**, the latest non-yanked release checked on 2026-11-07.
Unlike preview.2, this release removes high-level actor state, connection state and queue handlers.
The Ruby binding retains those APIs through core's public factory, snapshot and queue events,
while continuing to use the high-level actor runner for actions, connections and lifecycle hooks.
The TypeScript interoperability client stays at **2.3.30** to check older-client compatibility.

### Rivet 3.0 preview engine

The runnable stack targets **3.0.0-preview.2**, independently of the Rust SDK pin above.
The [preview announcement](https://rivet.dev/changelog/2026-10-26-introducing-rivet-3-0-preview/)
explicitly retains the 2.x SDK/protocol; a matching SDK version number is not required.
The [published release](https://github.com/rivet-dev/rivet/releases/tag/v3.0.0-preview.2)
points to source `62f8eec8ccc74a7b08f4d11036635039584aea7d`. Docker Hub serves
`rivetdev/engine:3.0.0-preview.2` at manifest digest
`sha256:5698157c4f44f98290bf25ac6c3b7465abe38ce34b7058057c14da56ab8590ce`.

Configuration follows that release's source, not the old 2.x self-host example:

- [`engine/packages/config/src/config`](https://github.com/rivet-dev/rivet/tree/v3.0.0-preview.2/engine/packages/config/src/config):
  `storage.log_directory`, `storage.auto_provision_partitions`, and `object_storage.primary.s3`
  replace the old root `file_system` configuration. Wildcard peer binds require `api_peer.advertise_address`.
- [`engine/packages/guard/src/lib.rs`](https://github.com/rivet-dev/rivet/blob/v3.0.0-preview.2/engine/packages/guard/src/lib.rs)
  mounts `api-public-shim`, whose pool setup is `PUT /pools/{pool}?namespace=default` with `{}`.
  The old `api-public` source still contains `/runner-pools`, but that router is not mounted by this engine.
- The binary starts with `--config`, without the old `start` subcommand. `/health` reports
  `architecture: v3` and `version: 3.0.0`; the image digest identifies the exact preview release.
- Silo supplies a dedicated `rivet-engine-preview` bucket for engine object storage and a separate
  `rivet-local` bucket for Ruby AWS SDK examples. `AWS_ALLOW_HTTP=true` permits local Silo HTTP.
  This single-node setup retains local log/cache and Silo volumes; it does not demonstrate HA or disk-loss recovery.

No 2.x data migration is attempted: the preview uses a new engine volume. The announced migration
tool and preview support for multi-region, serverless, and ACLs are not yet available.

## How TypeScript works

The relevant code is under `rivetkit-typescript/packages`:

- `rivetkit/src/actor/definition.ts`, `actor/config.ts`, `actor/actions.ts`: `actor({...})` definitions,
  lifecycle hooks, action flattening and validation.
- `rivetkit/src/registry/native.ts`: adapts JavaScript actor definitions, state and lifecycle to the native runtime.
- `rivetkit/src/registry/write-through-proxy.ts`: tracks nested state mutations for persistence.
- `rivetkit/src/registry/runtime.ts`, `napi-runtime.ts`: runtime-neutral handles and the native adapter.
- `rivetkit-napi/src/actor_factory.rs`, `napi_actor_events.rs`: Rust factory, callback dispatch and native lifecycle loop.
- `rivetkit-napi/src/actor_context.rs`, `database.rs`, `connection.rs`, `queue.rs`: context and storage bindings.
- `rivetkit/src/client/actor-handle.ts`, `actor-conn.ts`, `queue.ts`: HTTP actions, reconnecting WebSocket actions/events, queue request/reply.
- `rivetkit/src/engine-client/api-utils.ts`: control-plane REST calls, including bearer authentication.

The TypeScript runtime is not simply a REST wrapper. It delegates persistence, SQLite, connections,
queues, schedules and engine coordination to **Rust core**. Its N-API callbacks use Node's thread-safe
callback facility. Ruby has no equivalent permission to call into the VM from an arbitrary Rust worker.

Actions and events use positional argument arrays encoded as JSON-compatible CBOR inside Rivet's
versioned protocol. A single Array argument requires an outer argument array. Queue bodies are single
values, not positional arguments. Reusing the Rust client avoids hand-writing the Bare/CBOR transport,
metadata discovery, gateway routing and reconnect logic.

## Ruby bridge selected

```text
Ruby DSL / actor instances                  Ruby client / subscriptions
          |                                           |
    Ruby-created worker threads               Magnus synchronous calls
          | native requests + oneshot replies          |
          +------------------+------------------------+
                             |
               shared multi-thread Tokio runtime
                 rivetkit Actor / Ctx / client
                             |
                  Rivet engine (remote SQLite)

Ruby actor -- aws-sdk-s3 --> Silo (separate blob storage)
```

One Rust `RubyActor` implements the public `Actor` trait. Input and connection parameters use
`serde_json::Value`; each activation's broker owns its JSON state behind a native mutex, and
connection state uses the core connection handle's CBOR bytes. No Ruby `VALUE`,
Proc or exception crosses into Tokio or is stored in a Rust collection.

Dynamic `ActionSet` and core queue-event dispatch check the Ruby declarations before calling Ruby.
Unknown names preserve Rivet's not-found errors. `Actor::Action = Raw` alone is
**not** a wildcard dispatcher. The inspector gets owned action names through the pinned core config.

We use core's public `ActorFactory` with explicit startup readiness. The broker restores the state
snapshot or calls Ruby's state initializer, then scopes the standard `run_actor` with Tokio task-local
storage. A receive loop handles state serialization and declared Ruby queue callbacks and forwards
other events to the standard runner. This keeps core's persistence/final-save machinery and the
runner's lifecycle/connection handling without a global singleton registry. After creation the Rust
actor owns its broker directly, including for spawned action tasks.
`serve_with_config` and a cancellation token leave signals and process ownership with Ruby.

The Ruby registry polls for native callback requests, dispatches them on Ruby-created threads, and
returns native oneshot replies. A callback object owns its context and pending reply. Ruby objects
stay in Ruby containers where GC can see them. Native context/client I/O releases the GVL through a
small `rb-sys` boundary; native panics are caught before returning across that C boundary.

State is held by Rust. The Ruby getter returns a frozen snapshot; `state=`/`update_state` write it
back and request a core save. Serialization supplies a CBOR `ActorState` delta through the same
core persistence path as before. This intentionally avoids porting JavaScript's deeply nested
write-through proxy to Ruby in an experiment. SQLite transactions use actual native transaction
handles, not unrelated `BEGIN`/`COMMIT` queries through a pooled connection.

## What testing exposed

1. **REST auth differs from gateway auth.** The Rust client sends `x-rivet-token`, while 2.3.30's
   control-plane REST API expects `Authorization: Bearer ...`. A direct check returned 401 using only
   `x-rivet-token`; the bearer header passed authentication. Configure the existing Rust client header
   API with the bearer token too. Without this, HTTP actions work but `id`/`create` fail authentication.
2. **Actor keys have a tagged internal Rust representation.** Serialize the segment values for Ruby,
   not `[{"String":"part"}]`. The integration test compares actor context identity to its original key.
3. **Abort is not the same as cleanup completion.** Rivet aborts an actor before `on_sleep`; that hook
   must still be able to mutate state for the final save. Reject a closed callback reply, not merely
   an aborted actor, when accepting a state update. Sleep/wake tests check the hook's persisted change.
4. **Concurrent cold get-or-create can race upstream.** Reproduced `actor/destroyed_during_creation`.
   Upstream's `engine/tests/envoy/api_actors_get_or_create.rs` explicitly handles this race too.
   Resolve a shared handle before testing concurrent state mutations; document the cold-creation limit.
   Do not blindly retry potentially non-idempotent action requests.
5. **A WebSocket action can otherwise wait indefinitely while reconnecting to a missing actor.**
   The Ruby call API supplies a client deadline. Cancellation still does not undo external side effects.
6. **Engine storage differs between releases.** The original 2.3.30 image rejected S3 configuration
   and used RocksDB. The 3.0 preview setup above uses Silo for engine object storage as well as
   actor-owned blobs, in distinct buckets. The blob test alone is not evidence of engine S3 storage.
7. **Preview runner restart is eventual recovery.** With 2.3.30 SDKs and preview.2, the unchanged Ruby
   suite passed (16 runs, 65 assertions, no skips), as did the TypeScript interoperability test.
   An active actor initially timed out across restart. Docker's 10-second grace period killed the
   runner (exit 137); 45 seconds allowed exit 0 after the SDK's 30-second drain deadline. Even then,
   the preview waited for the old runner's lost threshold and could expire gateway requests.
   `test/runner_restart.sh` retries read-only recovery probes and verified the same actor ID, changed
   activation, retained state/SQLite/KV, and a new subscription after 45.09 seconds of recovery.
   The sleep counter remained zero on this restart: do not infer that `on_sleep` ran or that unsaved
   state is safe. This is single-node Linux host-network verification, not HA, disk-loss recovery,
   uninterrupted connections, or a 2.x migration test.

## Alternatives and remaining work

A Ruby-only HTTP/WebSocket client is feasible, but would duplicate protocol codecs, routing,
reconnection and persistence integration. A pure-Ruby actor host would have to implement the engine's
runner protocol as well. Neither is necessary for this experiment: the published Rust SDK builds and
the native bridge works end to end, including calls from the actual TypeScript client.

This is not full TypeScript SDK parity. Workflows, streaming/hibernatable raw WebSockets, serverless
hosting, cron management, schema generation, Fiber integration and
a complete structured application-error API remain unimplemented. See README for supported APIs,
threading constraints, build commands and reproducible tests.

## Audit: 2026-11-07

Baseline: `origin/main` at [the orb setup commit](https://github.com/catkins/rivet-rb/commit/0fb6206353aa930752537ef7f5d463385b95f828), with a clean worktree.
The review covered all Ruby wrappers and native bridge modules, their callers and tests, then
separately checked which layers could be removed without losing behavior. It was performed in one
thread, without delegating. [Audit conversation](https://ampcode.com/threads/T-01a1b49b-3e59-751f-9306-becceb91e0eb).

### Comparison sources

The main comparison is **Rust 3.0.6 versus TypeScript 3.0.6**, not Rust 3.0.6 versus the older
interoperability fixture. Both SDKs are in upstream tag
[`v3.0.6`](https://github.com/rivet-dev/rivet/tree/e1ec8e6d36c580028badeddd717b6b74a8794e45).
The published Rust `rivetkit`, `rivetkit-core` and `rivetkit-client` packages' entire `src/` trees
were compared with that tag: no differences. npm reports the same commit as `rivetkit@3.0.6`'s
`gitHead`. The committed TypeScript fixture remains **2.3.30**; it was not upgraded by this audit.
The local integration engine remains **3.0.0-preview.2**, at the digest in Compose.

Primary source entry points at that tag:

- Rust [`Actor` and runner](https://github.com/rivet-dev/rivet/tree/v3.0.6/rivetkit-rust/packages/rivetkit/src):
  `actor.rs`, `start.rs`, `context.rs`, `registry.rs`, `serverless_listener.rs`.
- Rust [client](https://github.com/rivet-dev/rivet/tree/v3.0.6/rivetkit-rust/packages/client/src):
  `client.rs`, `handle.rs`, `connection.rs`, `remote_manager.rs`.
- Rust [core actor APIs](https://github.com/rivet-dev/rivet/tree/v3.0.6/rivetkit-rust/packages/rivetkit-core/src/actor):
  `config.rs`, `context.rs`, `queue.rs`, `schedule.rs`.
- TypeScript [`actor/config.ts`](https://github.com/rivet-dev/rivet/blob/v3.0.6/rivetkit-typescript/packages/rivetkit/src/actor/config.ts),
  [`actor/errors.ts`](https://github.com/rivet-dev/rivet/blob/v3.0.6/rivetkit-typescript/packages/rivetkit/src/actor/errors.ts),
  [`client`](https://github.com/rivet-dev/rivet/tree/v3.0.6/rivetkit-typescript/packages/rivetkit/src/client),
  [`registry/native.ts`](https://github.com/rivet-dev/rivet/blob/v3.0.6/rivetkit-typescript/packages/rivetkit/src/registry/native.ts)
  and [`workflow`](https://github.com/rivet-dev/rivet/tree/v3.0.6/rivetkit-typescript/packages/rivetkit/src/workflow).

### Findings and changes

**Verdict: needs attention before production use; the experimental bridge works.**

1. **Fixed — failed startup reused activation-local Ruby state.** `Registry` cached instances by
   actor ID but removed them only on sleep/destroy. Rust returns directly on startup failure,
   without those hooks. A real actor whose `on_start` increments `@starts` and raises when it is
   1 failed its first activation, then incorrectly served an action returning 2 on the next
   activation. Instances are now owned by the native activation identity, not by actor ID or hook
   names. A native completion guard marks finished activations even when their future is dropped;
   the dispatcher prunes them and retains the context while cached to prevent pointer reuse.
   The retained public registry/client regression never serves a later action from the failed
   instance. Sleep/wake tests also check a new activation and retained durable state.
2. **Fixed — SQL could silently bind oversized Ruby integers as REAL.** Rust's JSON parser accepts
   numbers outside its integer range as floats before the native SQL integer guard sees them.
   `SQL#execute` now raises `RangeError` before encoding integer binds outside SQLite's signed
   64-bit range. `query` and transaction handles share this boundary. A retained regression test
   checks rejection before native I/O; live probes check both valid endpoints and ordinary floats.
3. **Fixed — general JSON serialization silently rounded oversized integers.** Actions sent
   −9223372036854775809 or 18446744073709551616 returned floats. One Ruby serializer now checks the
   actual serialized tree before all Ruby-to-native JSON crossings, including custom `to_json`
   output. It rejects integers outside −2⁶³ through 2⁶⁴−1 with `RangeError`. Actor-produced invalid
   results become normal action failures, not rounded successes. Decimal strings remain the
   cross-language workaround; already-rounded TypeScript numbers cannot be recovered. Enabling
   serde_json's `arbitrary_precision` was rejected: its private Number serialization changes CBOR
   encoding, including ordinary integers, and would affect the shared upstream dependency.
4. **Fixed — callback load and shutdown could grow or wait without bound.** Admission now caps
   live Ruby callback threads at 16 work / 4 lifecycle by default, with separate 64-entry native
   channels. Full capacity rejects with upstream's typed overload error; `try_send` never blocks
   a Tokio worker. There is no extra Ruby queue or worker-pool hierarchy. Work waiting for an
   actor lock counts toward the cap; lifecycle slots remain available during work saturation.
   Shutdown keeps dispatching cleanup, uses one 45-second default deadline, then cancels replies
   and aborts the runner task. A timed-out registry cannot restart while its Ruby callbacks live.
   These limits do not bound all upstream allocations or forcibly stop user Ruby/native code.
5. **Fixed — deadlines did not cover ID resolution, eager create, queues or fetch bodies.** A
   shared native deadline wraps the complete async operation, including discovery and response
   bytes. `Client.new(timeout: 30)` sets the default; the blocking public operations accept an
   override. Positive finite seconds are required; zero-timeout `send_and_wait` is no longer
   accepted (use `send_message`). Connection close bounds native disposal and shares remaining
   time across listener joins; cleanup attempts every subscription even if one fails. The stalled
   TCP fixture supplies headers but withholds body bytes, so a headers-only timeout cannot pass.
   A timeout does not undo side effects; no automatic mutation retries were added.
6. **Fixed — inconsistent native exceptions and accidental remote coercion calls.** Native
   failures consistently raise `Rivet::Error`; binding deadlines raise `Rivet::TimeoutError`.
   Argument and JSON validation retain normal Ruby exception classes. Implicit coercion,
   pattern-matching and Marshal protocols are excluded from dynamic actions. Tests caught the
   additional `Integer(handle)` fallback to `to_i`, beyond `to_int`. Explicit `call(:to_ary)`
   still works against the engine. **Remaining:** application errors still lack a complete
   machine-readable group/code/metadata contract and a public-error declaration API.

The useful simplification was actor-local ownership of definitions: each native bridge now holds
only its own shared definition, rather than retaining and indexing the entire registry on every
action/queue dispatch. Actor config is initialized directly as a Rust struct. The factory/event
adapter itself remains necessary: deleting it would lose managed state persistence and queue
handlers removed from the high-level Rust trait. Ruby references to their client also remain
necessary: upstream `Client::drop` shuts down its connections. The state and action mutexes serve
different contracts and were not merged.

### Prioritized feature coverage

P1 is the next useful slice, not a request to implement everything. P2 is demand-driven; P3 should
stay deferred unless an application needs it. Production correctness issues above precede parity.

| Area | Ruby coverage | Rust 3.0.6 / TypeScript 3.0.6 comparison | Priority |
| --- | --- | --- | --- |
| Discovery and actions | `get`, `get_or_create`, `create`, ID lookup; positional HTTP/WS actions; total operation deadlines | Core use cases covered. Missing client close/dispose, optional resolution, reload, gateway URLs and custom headers. Rust also exposes encoding/transport/input-size/metadata options; TS adds token renewal, token issuance and retry-budget controls. | P1: client close; P2: remaining options |
| Identity, input, ephemeral data | Identity and initializer input; ordinary Ruby instance variables | Rust has `ctx.input()` in later hooks; Ruby does not. TS `vars` has a different API, not a missing Ruby storage mechanism. | P2: input accessor |
| Durable data | Frozen JSON state, SQL typed binds/rows/transactions; KV CRUD | TS retains deprecated state/connection-state APIs and a write-through proxy. Rust high-level state is removed; core still supports snapshots. SQL is the preferred 3.0 durable store. Ruby need not copy the JS proxy or database-provider/ORM layers. | Covered basics; P2: migration ergonomics |
| Lifecycle | Create/start/sleep/destroy and connection hooks | Ruby `on_start` runs on every activation, like TS `onWake`; it is not a migration hook. TS also has `onMigrate`, `onStateChange`, `onBeforeActionResponse`. Rust has `run`, task registration and keep-awake scopes. | P1: migration hook and scoped background work |
| Events and connections | Broadcast, targeted emit, subscriptions, unsubscribe, status, block cleanup | Rust/TS also expose once/open/close/error/status listeners; TS has `ready` and connection IDs. Hibernated-connection restoration is not wired into Ruby. | P1: readiness/error visibility; P2: richer listeners |
| Scheduling | Relative `after`, returning an ID | Both have absolute `at`, cancel/get/list, cron set/every/get/list/delete/history. Ruby also omits scheduled-fire metadata. | P1: cancel/get/list/at; P2: cron |
| HTTP and WebSockets | Buffered binary fetch and Rack-shaped response triples; SDK action sockets | Both upstreams support raw WebSockets and streaming HTTP. Request headers are not exposed in Ruby action/preconnect context. Rust also has opt-in bounded concurrent HTTP callbacks. These are not supplied merely by using the Rust runner. | P2: request context; P3: streaming/raw sockets |
| Hosting | Long-lived runner, explicit Ruby signal ownership | Rust core supports serverless runtime construction; the high-level Rust/TS hosting layers supply HTTP adapters. Ruby's core `serve_with_config` call does not supply that adapter. Preview engine support is a separate constraint. | P3 |
| Queues and KV | Manual queue send/next, client handlers/replies; KV CRUD | Deprecated in 3.0. Rust high-level queue handlers are removed, while core and TS retain them. Batch/completable queue operations and KV list/batch APIs are missing bindings, but low-value parity targets for new code. | P3 |
| Errors, validation, telemetry | Consistent native error/timeout classes; local exception logging; explicit action allowlist; integer validation | TS has structured public/user errors, runtime schemas and tracing controls. Rust uses typed serde/action/event contracts and tracing. Ruby has neither TS schema generation nor automatic equivalent runtime validation. | P1: structured public errors; P2: validation/tracing |
| Workflows | None | TS has an experimental workflow driver/context. Rust has lower-level run/alarm and inspector events, not an equivalent high-level workflow DSL. This is partly an upstream SDK difference, not simply omitted Rust methods. | P3 |
| S3 and Ruby async | AWS SDK example; blocking calls release the GVL | S3 is an application integration, not a Rivet storage binding. Ruby Fiber scheduling and MRI fork safety are Ruby-specific concerns, not TS parity features. | Keep current S3 integration; defer Fiber integration |

### Validation and limits

- Initial `bundle exec rake test`: 16 tests, 9 assertions, no failures, 12 integration skips.
- Native debug extension rebuilt with `RB_SYS_CARGO_PROFILE=dev CARGO_BUILD_JOBS=2 bundle exec rake compile`.
- `cargo clippy --locked --lib -- -D warnings` and `git diff --check` passed.
- Initial audit tests with `RIVET_ENDPOINT` and local Silo credentials: **17 tests, 72 assertions, no failures,
  errors or skips**. This includes persistence after sleep, SQL rollback, connection isolation,
  actions/events, queues, schedules and S3 bytes read independently of the actor.
- Final hardening run, `bundle exec rake test` with the real preview engine and Silo:
  **22 tests, 130 assertions, 0 failures, 0 errors, 0 skips**. Native rebuild, Clippy with warnings
  denied, rustfmt check and diff whitespace check also passed. Both TypeScript versions below
  were rerun against the rebuilt runner.
- `npm test --prefix test/interop`: real TypeScript **2.3.30** client passed HTTP actions, WS
  actions/events, JSON and queue replies. The same script also passed with **3.0.6** installed in a
  disposable directory; the committed dependency pin was left unchanged.
- The SQL rejection regression failed against the original Ruby implementation and passed after
  the change. Live checks preserved −2⁶³, 2⁶³−1 and 3.25, and rejected three oversized integer binds
  constructed inside Ruby from decimal strings, avoiding prior rounding at the action boundary.
- The retained registry test uses the real engine in an isolated pool. It checks startup instance
  isolation, actor-generated invalid integers, explicit coercion-named actions, HTTP/WS overload,
  a connection hook while work is saturated, shutdown with a non-cooperating callback, refused
  restart while that callback lives, and rejected state mutation after cancellation.
- Integer action roundtrips preserve −2⁶³, 2⁶³−1 and 2⁶⁴−1. Retained tests reject oversized nested
  input/arguments/queue bodies before network I/O. Before hardening, `Array(handle)` issued a
  remote `to_ary` action; now Array, string and numeric conversions remain local.
- Loading the baseline client wrapper against the native extension reproduced Integer → Float
  loss through a live echo action; the final wrapper rejects the same input before network I/O.
  A temporary live probe blocked two event listeners, timed out connection close, released them,
  and checked that both listener threads stopped. The stall fixture also checks HTTP body timeout.

The integration stack used the documented host-network override, Docker's `vfs` driver, the pinned
preview engine and Silo release, and a Ruby runner on the orb. This was not a release-profile build,
a load/soak test, a runner-restart rerun, an HA test, a disk-loss test, a 2.x migration, a serverless
hosting test or a proof of production readiness. Forced shutdown is tested at the bridge boundary,
not as proof that every upstream task has terminated or external side effects have stopped.
Structured application errors, event-buffer backpressure, client-wide disposal and operational
load/recovery testing remain work before production use. Poll-only event buffers remain unbounded;
the callback admission cap does not apply to client event subscriptions.
