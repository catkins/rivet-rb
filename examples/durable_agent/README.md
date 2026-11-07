# A durable RubyLLM agent

One actor key identifies one text conversation. RubyLLM handles model requests and tool schemas;
the actor owns the durable loop. No Rails, ActiveRecord, Sequel, or Node.js process is needed.
RubyLLM is an example/development dependency, not a dependency of the Rivet gem itself.

This implements Pi Durable's core interruption rules for model calls and tools. It is **not**
a port of the whole Pi agent framework, nor a promise of exactly-once external effects.

## Run with Docker Compose

From the repository root, with `OPENAI_API_KEY` supplied in your environment:

```sh
docker compose -f compose.yaml -f examples/durable_agent/compose.yaml up --build -d
docker compose -f compose.yaml -f examples/durable_agent/compose.yaml exec runner \
  bundle exec ruby examples/durable_agent/client.rb \
  'Remember that my favourite colour is green, then recall it.'
```

This uses the base stack's Rivet preview engine and Silo storage, but replaces the counter runner
with the agent runner. Do not leave another runner with different actor registrations in the same
pool. The default model is `gpt-4.1-mini`. Set `AGENT_MODEL`, `AGENT_PROVIDER` and the matching provider
credential to use another model; this example wires OpenAI and Anthropic credentials.
For an OpenAI-compatible endpoint, set `AGENT_API_BASE` and `AGENT_PROTOCOL=chat_completions`.
An endpoint inside another container must be reachable from the runner, not its loopback address.

`remember` and `recall` work without another service. Optional `lookup` and `publish` tools require
`AGENT_TOOL_ENDPOINT`: a service accepting `GET /lookup?topic=...` and `POST /publish` with
`{"text":"..."}`, returning a JSON response. `publish` sends a persisted `Idempotency-Key` header;
the remote service must implement deduplication if it wants to use that key. No arbitrary shell
or model-chosen URL execution is provided.

For the orb's host-network workaround, insert `-f docker/compose.host.yaml` after `-f compose.yaml`
in these commands. All three files compose together.

For a local Ruby 4 development build, use the base README's build instructions, stop the Compose
runner, and run `bundle exec ruby examples/durable_agent/server.rb` with the engine and provider
environment variables set. Run `client.rb` in a second process with the same engine configuration.

## Client API

```ruby
require "rivet"

client = Rivet::Client.new(pool: "default")
agent = client.get_or_create(:durable_agent, ["my-assistant"])

agent.submit("Remember that the release is on Friday.", "request-001")
snapshot = agent.snapshot
agent.cancel("request-001")
```

`submit` only commits the request; it does not wait for the model. Reusing a request ID with the same
prompt returns the original request, even after completion or cancellation. A different prompt with
the same ID is rejected. The sample client prints the request ID and polls until the run finishes.
Use `REQUEST_ID` and `AGENT_KEY` to reconnect to the same run after a client disconnect.

`snapshot` returns ordered runs, messages, tool intents/results, and notes. It is authoritative;
`agent.message` broadcasts are best-effort notifications for committed assistant messages, not a
durable event stream. The run hook is independent of the action mutex, so status and cancellation
remain available during model and external HTTP waits. A local SQL tool holds the database
transaction until its result is saved; keep these tools short and free of network I/O.

`sleep_now` requests sleep; `destroy_agent` destroys the conversation. Normal idle sleep happens
after five seconds. Activation starts the worker again and rebuilds the chat from SQLite. While
working, `ctx.keep_awake` prevents idle sleep; it cannot prevent crashes or explicit shutdown.
After a failed runner is replaced, the engine reactivates the actor and work resumes without a
client request. The crash test checks this without polling the actor during recovery.

## What survives an interruption

| Interrupted boundary | Recovery |
| --- | --- |
| Request committed, model not started | Continue the queued run. |
| Model request in flight, response not committed | Repeat that generation using the saved transcript. A provider may charge for both attempts. |
| Assistant message/tool requests committed | Restore the same message and tool-call IDs; do not regenerate them. |
| Tool result committed | Restore the result; do not execute the call again. |
| `remember` / `recall` in flight (`local`) | Replay. Note changes and the result share one SQLite transaction, so either both commit or neither does. |
| `lookup` in flight (`safe`) | Replay the read-only operation. Its returned value can change between attempts. |
| `publish` in flight (`never`) | Do not replay. Save a tool result saying **outcome unknown; it may already have happened**, with the original tool-call ID. Continue the conversation. |
| Cancellation committed | Do not resume that run. Ignore late model/tool results. An external effect may already have happened. |
| Model failure with saved retry time | Retry with persisted exponential backoff and a scheduled wake, up to five failed generations per run. |

The intent is committed **before** invoking an external tool. Its result is committed **after** it
returns. SQLite cannot atomically commit a remote service's write. An unsafe tool can therefore have
an unknown outcome even if it never reached the service. Do not label a write `safe` merely because
it usually succeeds; use a genuinely idempotent service and reuse the saved key if you add that policy.
These rules stop replay of a particular call, not a model inventing a new call with the same meaning.

`agent_runs` stores prompts, model/provider/protocol settings, retry state and cancellation.
`agent_messages` stores RubyLLM's JSON transcript, including reasoning/signatures and correlated tool
results. `agent_tools` records each call's policy, stable idempotency key and progress. `agent_notes`
is the example tool's application data. Keys include the actor, run, assistant turn and tool-call ID,
so a provider reusing a call ID in a later turn does not collide with earlier results.

## Recovery tests without paid model calls

The test suite runs the real extension and engine against a deterministic local OpenAI-compatible
HTTP fixture. It spawns its own isolated Ruby runner pools, actually sends SIGKILL, and restarts the
runner at model, tool and local-transaction boundaries. No model-provider API key is used.

```sh
docker compose -f compose.yaml -f examples/durable_agent/compose.yaml --profile test run --rm test
```

Or, against the already running local engine:

```sh
RIVET_ENDPOINT=http://127.0.0.1:6420 RIVET_TOKEN=dev RIVET_NAMESPACE=default \
  RIVETKIT_ENGINE_SPAWN=never bundle exec ruby -Itest test/durable_agent_test.rb
```

Recovery must wait for the engine to notice the lost runner; the tests allow 100 seconds per crash.
They check committed-step reuse, safe versus unsafe replay, atomic local changes, request-ID
deduplication, cancellation, sleep/wake, and model retry. This does not test provider quality, engine
disk loss, or high-availability failover. Keep the engine and Silo volumes.

## Deliberate limits

- Text and JSON tools only. Attachment descriptors are not durable file contents. There is no
  streaming UI, branching, human approval protocol, sandbox, or generic checkpointed multi-phase
  task API. Model/tool boundaries are the checkpoints; split multi-step work into separate calls
  or add an explicit phase journal before claiming Pi task-level parity.
- The transcript preserves RubyLLM's serialized messages and observed aggregate cost, not its raw
  HTTP objects or complete per-attempt accounting ledger. Replay of opaque reasoning still depends
  on using the same provider/protocol. API keys and endpoint addresses remain environment config.
- One run at a time per conversation, sequential tool execution, no transcript pruning or quotas.
  This is not a secured multi-tenant service: add authentication, authorization, input limits and
  tool policy before exposing it to untrusted callers.
- Cancellation is cooperative, not forced HTTP interruption. Blocking requests have timeouts.
  Background hooks use bounded callback slots (`background_workers: 16` by default); use more
  runner processes or adjust admission deliberately for more simultaneously active conversations.
- Database commits and schedule creation are separate operations. Retry times survive, and
  reactivation reschedules them, but this is not a transactional outbox guaranteeing wake delivery
  through every engine failure. Unexpected non-provider exceptions stop the activation rather
  than being hidden in an unlimited retry loop.
- This remains an experiment on the preview engine, not a production durability or HA guarantee.
