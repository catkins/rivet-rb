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

The crate index also contains `3.0.0-preview.2`. That preview differs from current main in actor,
action, context, registry, startup and persistence code. Packaged **2.3.30** source matched all checked
`src/` files for `rivetkit` (16), `rivetkit-core` (63), and `rivetkit-client` (16). Pin stable exactly.
The published crate's repository metadata names `rivet-ee`, but its packaged SDK source is inspectable
and matched the public monorepo. Use published packages; no Git checkout or Rivet fork is required to build.

### Rivet 3.0 preview engine

The runnable stack now targets **3.0.0-preview.2**, while retaining the **2.3.30 SDKs** above.
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

One Rust `RubyActor` implements the public `Actor` trait. Its state/input/connection state are
`serde_json::Value`; the associated Rust types remain serializable and Send/Sync. No Ruby `VALUE`,
Proc or exception crosses into Tokio or is stored in a Rust collection.

Dynamic `ActionSet` and `QueueSet` implementations check the Ruby declarations before dispatching.
Unknown names return `None`, preserving Rivet's action-not-found path. `Actor::Action = Raw` alone is
**not** a wildcard dispatcher. The inspector gets owned action names through the pinned core config.

We use the public, currently deprecated `Registry::register_with` entry to scope a callback broker
per registry activation with Tokio task-local storage, then call the standard `run_actor`. This avoids
a global singleton registry and avoids copying Rivet's startup, snapshot, final-save and connection
machinery. After creation the Rust actor owns its broker directly, including for spawned action tasks.
`serve_with_config` and a cancellation token leave signals and process ownership with Ruby.

The Ruby registry polls for native callback requests, dispatches them on Ruby-created threads, and
returns native oneshot replies. A callback object owns its context and pending reply. Ruby objects
stay in Ruby containers where GC can see them. Native context/client I/O releases the GVL through a
small `rb-sys` boundary; native panics are caught before returning across that C boundary.

State is held by Rust. The Ruby getter returns a frozen snapshot; `state=`/`update_state` write it
back and mark it dirty through `Ctx`. This intentionally avoids porting JavaScript's deeply nested
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
hosting, cron management, schema generation, a bounded callback worker pool, Fiber integration and
a complete structured application-error API remain unimplemented. See README for supported APIs,
threading constraints, build commands and reproducible tests.
