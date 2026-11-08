# Development and operations

[README](../README.md) · [API](api.md) · [SQLite](sqlite.md) · [Concurrency](concurrency.md)

Commands below run from the repository root. Start with the [Docker quickstart](../README.md#docker-quickstart)
for the local-only credentials and standard stack.

## Storage and restarts

**Engine storage and actor-owned blobs are separate.** WarpDrive manages Rivet state and SQLite
using its local log/cache in `engine-preview-data` and the `rivet-engine-preview` S3 bucket.
The example independently uses `aws-sdk-s3` to put/get objects in `rivet-local`; it does not access
the engine bucket. Both buckets live in Silo's `s3-data` volume. The blob test reads uploaded bytes
directly through S3, sleeps the actor, and reads them through the reactivated actor.

**Keep both volumes when restarting this single-node setup.** `docker compose down` retains them;
`docker compose down -v` deletes this experiment's data. This is not a three-node replicated
deployment or a test of disk-loss recovery. The development engine caps its local log at 1 GiB
and disk cache at 256 MiB instead of auto-sizing from host free space. Leave room for these,
Silo objects and Docker build caches.

This is a **3.x deployment, not a 2.x data migration**. The engine does not reuse the old
`engine-data` RocksDB volume. Existing 2.x data is left untouched but unavailable here.
The volume and bucket retain their `preview` names so upgrading an existing Compose stack
does not create empty storage. Do not rename or delete them as an upgrade cleanup.

The stack runs the `default` runner pool and [PGSTY Silo](https://github.com/pgsty/silo), pinned to
`RELEASE.2026-10-26T00-00-00Z`. Engine and SDK versions are listed in the [README](../README.md).

## Host-network workaround

If an orb cannot forward Docker bridge traffic, use the supplied Linux override:

```sh
docker build --network host --allow network.host -t rivet-rb:local .
docker compose -f compose.yaml -f docker/compose.host.yaml up --no-build -d
docker compose -f compose.yaml -f docker/compose.host.yaml --profile test run --rm test
```

**Trusted development hosts only:** host networking bypasses loopback-only port mappings.
The [durable agent guide](../examples/durable_agent/README.md) explains composing its override too.

## Build without Docker

Requires **MRI Ruby 4.0+** with development headers, Bundler, stable Rust (edition 2024), a C
compiler, libclang and OpenSSL development headers. `.ruby-version` and Docker pin development
to Ruby 4.0.9. On Debian/Ubuntu the native-extension packages are
`build-essential libclang-dev libssl-dev pkg-config`; distro Ruby may be older than required.
This is a source gem; no precompiled platform gems are published.

```sh
bundle install
RB_SYS_CARGO_PROFILE=dev bundle exec rake compile
bundle exec ruby -Itest test/actor_test.rb
```

Omit `RB_SYS_CARGO_PROFILE=dev` for an optimized extension. `bundle exec rake` builds and runs
all Ruby tests; integration tests skip unless `RIVET_ENDPOINT` is set.

To use an existing engine, set `RIVET_ENDPOINT`, `RIVET_TOKEN`, `RIVET_NAMESPACE`,
`RIVET_POOL_NAME` and `RIVETKIT_ENGINE_SPAWN=never`. The pool must already exist; Compose creates
it through [docker/init-engine.sh](../docker/init-engine.sh). For the Compose engine, stop its
runner before hosting the example locally:

```sh
docker compose stop runner
RIVET_ENDPOINT=http://127.0.0.1:6420 RIVET_TOKEN=dev RIVET_NAMESPACE=default \
  RIVET_POOL_NAME=default RIVETKIT_ENGINE_SPAWN=never bundle exec ruby examples/server.rb
```

Do not use `RIVETKIT_ENGINE_AUTO_DOWNLOAD=1` to test this setup: automatic engine selection is
separate from the explicitly pinned image and storage configuration. Signal handling belongs
to Ruby; the example handles INT/TERM and calls `registry.stop`. See [shutdown](concurrency.md#shutdown-and-cancellation).

### Amp orbs

[.agents/setup](../.agents/setup) installs native build prerequisites, builds `.ruby-version`
under `~/.local/share/rivet-ruby`, prepares stable Rust, installs locked Ruby and TypeScript test
dependencies, and builds the debug extension with two Cargo jobs by default. The first build
takes several minutes; reruns reuse packages and caches. A repository-scoped login-shell hook
selects this Ruby for later commands and services. Node.js and npm are provided by the orb.
Rivet and Silo are not started automatically; use Compose for integration tests.

### YARD documentation

Public Ruby classes, methods, callbacks and generated DSL methods have YARD documentation.
Native implementation classes and dispatcher helpers are private API, not supported entry points.

```sh
bundle exec rake yard
bundle exec yard stats --list-undoc
```

Generated HTML is in `doc/index.html`. Neither `doc/` nor the `.yardoc` database is committed;
edit documentation sources, not generated output.

## Tests and interoperability

On Linux with Docker, `mise run ci` compiles the extension, runs rustfmt and Clippy, renders
YARD with 100% documentation coverage, then runs the full Ruby suite against real Rivet/Silo
services and the TypeScript **3.0.6** client. Skipped tests fail CI. Durable-agent tests use a
local model fixture, not a paid provider; see their [recovery tests](../examples/durable_agent/README.md#recovery-tests-without-paid-model-calls).

CI uses a separate Compose project with disposable volumes and the host-network override.
It needs ports 6420, 9000 and 9001 free; stop your development stack **without deleting its
volumes** first. Logs go to `tmp/ci-logs`; cleanup removes only CI's own containers and volumes.
Buildkite uploads logs as artifacts even on test failure.

The integration suite covers Unicode/nested JSON, action allowlists, identity/input, concurrent
updates, SQL types/commit/rollback, KV deletion, WebSocket events, connection state, unsubscribe,
queues, schedules, binary HTTP and persisted state/SQL/KV/S3 after sleep/wake.
`bundle exec rake test` also checks stalled-response deadlines, integer rejection and coercions;
with `RIVET_ENDPOINT`, it creates an isolated test pool for activation isolation, overload,
reserved lifecycle capacity and bounded shutdown. Run against the local development stack.
For a host runner, export `RIVET_ENDPOINT` and run:

```sh
bundle exec ruby -Itest test/integration_test.rb
```

S3 tests also require `S3_ENDPOINT`, `S3_BUCKET` and AWS credentials; Compose supplies them.

### Runner restart and recovery

With the Compose stack running:

```sh
bash test/runner_restart.sh
# With the orb host-network override:
bash test/runner_restart.sh -f compose.yaml -f docker/compose.host.yaml
```

This interrupts existing runner connections, checks the same actor ID with a new activation,
and verifies persisted state, SQLite, KV and a new WebSocket subscription. The engine can take
over 40 seconds to release an active actor from the old runner; requests during recovery can
hit client or gateway deadlines. The test retries only read-only `info` probes with a bounded
recovery window, not mutations.

Compose allows 45 seconds for runner shutdown because the SDK advertises a 30-second drain
deadline; the old 10-second grace period killed it. This is eventual recovery, not uninterrupted
service or a guarantee about unsaved state on SIGKILL. The durable agent's unattended recovery
uses engine alarms; its [guide](../examples/durable_agent/README.md#client-api) owns those details
and the model/tool crash boundaries.

### TypeScript interoperability

With the Compose stack running:

```sh
npm ci --prefix test/interop
RIVET_ENDPOINT=http://127.0.0.1:6420 RIVET_TOKEN=dev npm test --prefix test/interop
```

## Buildkite and caches

[The CI pipeline](https://buildkite.com/catkins-test/rivet-rb) uses the hosted Linux queue and the
same mise setup as `slatedb-rb`. [.mise.toml](../.mise.toml) pins Ruby, Rust and Node;
[post-checkout](../.buildkite/hooks/post-checkout) installs native build libraries before mise
installs Ruby.

[.buildkite/cache.yml](../.buildkite/cache.yml) defines entries for installed Bundler gems,
Cargo sources and compiled crates, and npm downloads. Keys include platform, Ruby/toolchain
configuration and lockfiles. Bundler and npm can restore older entries after lockfile changes.
Rust can fall back after source changes but requires matching toolchain, dependency and build
configuration checksums. Only this pipeline's `main` builds can save to the dedicated `rivet-rb`
registry; other branches can restore from `main`. The cluster's shared default registry is unchanged.

Hosted cache volumes provide best-effort `/mise` toolchain reuse. The keyed Rust cache restores
Cargo's registry under `/mise/rivet-rb-cargo` and compiled crates under `/mise/rivet-rb-target`,
without assuming the volume has the latest outputs. Both paths stay at the same absolute location
across jobs so dependency fingerprints do not reference deleted checkouts. Cargo still checks
source, toolchain and build configuration before reusing compiled crates.

Caches are optional accelerators: misses rebuild normally; compile, lint, docs and tests always
run. Test results, logs and engine/Silo data are not cached.
