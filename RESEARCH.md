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
6. **Engine S3 storage is not an option in this release.** The exact image rejects `s3` configuration.
   `engine/packages/config/src/config/db/mod.rs` supports PostgreSQL and FileSystem; filesystem maps to
   RocksDB in `engine/packages/pools/src/db/udb.rs`. Silo is therefore tested through actor-owned blobs,
   not mislabeled as engine state storage.

## Alternatives and remaining work

A Ruby-only HTTP/WebSocket client is feasible, but would duplicate protocol codecs, routing,
reconnection and persistence integration. A pure-Ruby actor host would have to implement the engine's
runner protocol as well. Neither is necessary for this experiment: the published Rust SDK builds and
the native bridge works end to end, including calls from the actual TypeScript client.

This is not full TypeScript SDK parity. Workflows, streaming/hibernatable raw WebSockets, serverless
hosting, cron management, schema generation, a bounded callback worker pool, Fiber integration and
a complete structured application-error API remain unimplemented. See README for supported APIs,
threading constraints, build commands and reproducible tests.
