use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use anyhow::{Result, anyhow};
use async_trait::async_trait;
use magnus::{Error, Ruby, prelude::*};
use rivetkit::{ActionSet, Actor, ConnCtx, Ctx};
use rivetkit_core::{ActorEvent, ActorFactory, ActorStart, StateDelta};
use serde_json::{Value, json};
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

use crate::runtime::{decode, encode, error, parse, runtime, wait, without_gvl};

tokio::task_local! { static BRIDGE: Arc<Bridge>; }

const CALLBACK_CAPACITY: usize = 64;

fn is_work(kind: &str) -> bool {
    matches!(kind, "action" | "queue" | "on_fetch")
}

fn overloaded(capacity: usize, operation: &str) -> anyhow::Error {
    rivetkit_core::error::ActorLifecycle::Overloaded {
        channel: "ruby_callbacks".to_owned(),
        capacity,
        operation: operation.to_owned(),
    }
    .build()
}

pub struct Bridge {
    tx: mpsc::SyncSender<Callback>,
    lifecycle_tx: mpsc::SyncSender<Callback>,
    definition: Arc<Value>,
    state: Mutex<Value>,
    finished: AtomicBool,
}

struct ActivationGuard(Arc<Bridge>);

impl Drop for ActivationGuard {
    fn drop(&mut self) {
        self.0.finished.store(true, Ordering::Release);
    }
}

impl Bridge {
    async fn call(
        self: &Arc<Self>,
        ctx: Ctx<RubyActor>,
        kind: &str,
        data: Value,
        conn: Option<ConnCtx<RubyActor>>,
    ) -> Result<Value> {
        let (tx, rx) = oneshot::channel();
        let sender = if is_work(kind) || kind == "run" {
            &self.tx
        } else {
            &self.lifecycle_tx
        };
        sender
            .try_send(Callback {
                ctx,
                bridge: self.clone(),
                kind: kind.to_owned(),
                data: data.to_string(),
                conn,
                reply: Mutex::new(Some(tx)),
            })
            .map_err(|error| match error {
                mpsc::TrySendError::Full(_) => overloaded(CALLBACK_CAPACITY, kind),
                mpsc::TrySendError::Disconnected(_) => anyhow!("Ruby dispatcher stopped"),
            })?;
        rx.await.map_err(|_| anyhow!("Ruby callback dropped"))?
    }

    async fn queue(
        self: Arc<Self>,
        ctx: Ctx<RubyActor>,
        name: String,
        body: Vec<u8>,
        conn: rivetkit::ConnHandle,
    ) -> Result<rivetkit_core::QueueSendResult> {
        if !self.definition["queues"]
            .as_array()
            .is_some_and(|names| names.iter().any(|v| v == &name))
        {
            return Err(rivetkit_core::error::ActorRuntime::NotFound {
                resource: "queue handler".to_owned(),
                id: name,
            }
            .build());
        }
        let abort = ctx.abort_signal();
        let data = json!({"name": name, "body": decode(&body)?});
        let result = tokio::select! {
            _ = abort.cancelled() => return Err(rivetkit_core::error::ActorLifecycle::Stopping.build()),
            result = self.call(ctx, "queue", data, Some(conn.into())) => result?,
        };
        Ok(rivetkit_core::QueueSendResult {
            status: rivetkit_core::QueueSendStatus::Completed,
            response: Some(encode(&result)?),
        })
    }

    async fn run(self: Arc<Self>, mut start: ActorStart) -> Result<()> {
        let ctx = Ctx::new(start.ctx.clone());
        let initial: Result<Value> = async {
            let state = match start.snapshot.as_deref() {
                Some(bytes) => decode(bytes),
                None => {
                    let input = match start.input.as_deref() {
                        Some(bytes) => decode(bytes)?,
                        None => Value::Null,
                    };
                    self.call(ctx.clone(), "create_state", input, None).await
                }
            }?;
            start.ctx.set_state_initial(encode(&state)?);
            Ok(state)
        }
        .await;
        match initial {
            Ok(state) => *self.state.lock().unwrap() = state,
            Err(error) => {
                if let Some(reply) = start.startup_ready.take() {
                    let _ = reply.send(Err(anyhow!("{error:#}")));
                }
                return Err(error);
            }
        }

        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let mut events = std::mem::replace(&mut start.events, rx.into());
        let runner = BRIDGE.scope(
            self.clone(),
            rivetkit::run_actor::<RubyActor>(rivetkit::start::wrap_start(start)?),
        );
        tokio::pin!(runner);
        loop {
            tokio::select! {
                result = &mut runner => return result,
                event = events.recv() => match event {
                    Some(ActorEvent::SerializeState { reply, .. }) => {
                        let state = encode(&self.state.lock().unwrap());
                        reply.send(state.map(|bytes| vec![StateDelta::ActorState(bytes)]));
                    }
                    Some(ActorEvent::QueueSend { name, body, conn, reply, .. }) => {
                        let bridge = self.clone();
                        let ctx = ctx.clone();
                        tokio::spawn(async move {
                            reply.send_or_cancel(bridge.queue(ctx, name, body, conn)).await;
                        });
                    }
                    Some(event) => {
                        if tx.send(event).is_err() {
                            return runner.await;
                        }
                    }
                    None => {
                        drop(tx);
                        return runner.await;
                    }
                }
            }
        }
    }
}

pub struct RubyActor {
    bridge: Arc<Bridge>,
}

#[async_trait]
impl Actor for RubyActor {
    type Input = Value;
    type Actions = Self;
    type Events = ();
    type ConnParams = Value;
    type Action = rivetkit::Raw;

    async fn create(_ctx: &Ctx<Self>) -> Result<Self> {
        Ok(Self {
            bridge: BRIDGE.get(),
        })
    }

    async fn run(self: Arc<Self>, ctx: Ctx<Self>) -> Result<()> {
        if self.bridge.definition["run"].as_bool() != Some(true) {
            return Ok(());
        }
        self.bridge
            .call(ctx, "run", Value::Null, None)
            .await
            .map(|_| ())
    }

    async fn on_create(self: Arc<Self>, ctx: Ctx<Self>) -> Result<()> {
        self.bridge
            .call(ctx, "on_create", Value::Null, None)
            .await
            .map(|_| ())
    }

    async fn on_start(self: Arc<Self>, ctx: Ctx<Self>) -> Result<()> {
        self.bridge
            .call(ctx, "on_start", Value::Null, None)
            .await
            .map(|_| ())
    }

    async fn on_sleep(self: Arc<Self>, ctx: Ctx<Self>) -> Result<()> {
        self.bridge
            .call(ctx, "on_sleep", Value::Null, None)
            .await
            .map(|_| ())
    }

    async fn on_destroy(self: Arc<Self>, ctx: Ctx<Self>) -> Result<()> {
        self.bridge
            .call(ctx, "on_destroy", Value::Null, None)
            .await
            .map(|_| ())
    }

    async fn on_before_connect(self: Arc<Self>, ctx: Ctx<Self>, params: &Value) -> Result<()> {
        self.bridge
            .call(ctx, "on_before_connect", params.clone(), None)
            .await
            .map(|_| ())
    }

    async fn on_connect(self: Arc<Self>, ctx: Ctx<Self>, conn: ConnCtx<Self>) -> Result<()> {
        let state = self
            .bridge
            .call(ctx.clone(), "create_conn_state", conn.params()?, None)
            .await?;
        conn.inner().set_state(encode(&state)?);
        self.bridge
            .call(ctx, "on_connect", Value::Null, Some(conn))
            .await
            .map(|_| ())
    }

    async fn on_disconnect(self: Arc<Self>, ctx: Ctx<Self>, conn: ConnCtx<Self>) {
        let _ = self
            .bridge
            .call(ctx, "on_disconnect", Value::Null, Some(conn))
            .await;
    }

    async fn on_subscribe(
        self: Arc<Self>,
        ctx: Ctx<Self>,
        conn: ConnCtx<Self>,
        name: String,
    ) -> Result<()> {
        self.bridge
            .call(ctx, "on_subscribe", json!(name), Some(conn))
            .await
            .map(|_| ())
    }

    async fn on_fetch(
        self: Arc<Self>,
        ctx: Ctx<Self>,
        req: rivetkit::Request,
    ) -> Result<rivetkit::Response> {
        let req = req.into_buffered().await?;
        let (method, url, headers, body) = req.to_parts();
        let response = self
            .bridge
            .call(
                ctx,
                "on_fetch",
                json!({
                    "method": method, "url": url, "headers": headers, "body": body,
                }),
                None,
            )
            .await?;
        let status: u16 = serde_json::from_value(response["status"].clone())?;
        let headers = serde_json::from_value(response["headers"].clone())?;
        let body = serde_json::from_value(response["body"].clone())?;
        rivetkit::Response::from_parts(status, headers, body)
    }
}

impl ActionSet<RubyActor> for RubyActor {
    fn entries() -> Vec<rivetkit::ActionEntry<Self>> {
        Vec::new()
    }

    fn dispatch(
        actor: Arc<Self>,
        ctx: Ctx<Self>,
        name: &str,
        args: &[u8],
    ) -> Option<Pin<Box<dyn Future<Output = Result<Vec<u8>>> + Send>>> {
        if !actor.bridge.definition["actions"]
            .as_array()?
            .iter()
            .any(|v| v == name)
        {
            return None;
        }
        let name = name.to_owned();
        let args = args.to_vec();
        Some(Box::pin(async move {
            let data = json!({"name": name, "args": decode(&args)?});
            let result = actor.bridge.call(ctx, "action", data, None).await?;
            encode(&result)
        }))
    }
}

#[magnus::wrap(class = "Rivet::NativeCallback", free_immediately, size)]
pub struct Callback {
    ctx: Ctx<RubyActor>,
    bridge: Arc<Bridge>,
    kind: String,
    data: String,
    conn: Option<ConnCtx<RubyActor>>,
    reply: Mutex<Option<oneshot::Sender<Result<Value>>>>,
}

impl Callback {
    fn lane(&self) -> &'static str {
        if self.kind == "run" {
            "background"
        } else if is_work(&self.kind) {
            "work"
        } else {
            "lifecycle"
        }
    }
    fn cancel(&self) {
        self.reply.lock().unwrap().take();
    }
    fn reject(&self, capacity: usize) {
        if let Some(tx) = self.reply.lock().unwrap().take() {
            let _ = tx.send(Err(overloaded(capacity, &self.kind)));
        }
    }
    fn kind(&self) -> String {
        self.kind.clone()
    }
    fn data(&self) -> String {
        self.data.clone()
    }
    fn context(&self) -> NativeContext {
        NativeContext(self.ctx.clone(), self.bridge.clone())
    }
    fn connection(&self) -> Option<NativeConnection> {
        self.conn
            .clone()
            .or_else(|| self.ctx.conn().cloned())
            .map(NativeConnection)
    }
    fn active(&self) -> bool {
        !self.bridge.finished.load(Ordering::Acquire)
            && self
                .reply
                .lock()
                .unwrap()
                .as_ref()
                .is_some_and(|tx| !tx.is_closed())
    }
    fn reply(&self, json: String, failure: Option<String>) -> Result<(), Error> {
        let result = match failure {
            Some(message) => Err(anyhow!(message)),
            None => Ok(parse(&json)?),
        };
        if let Some(tx) = self.reply.lock().unwrap().take() {
            let _ = tx.send(result);
        }
        Ok(())
    }
}

#[magnus::wrap(class = "Rivet::NativeRunner", free_immediately, size)]
pub struct NativeRunner {
    rx: Mutex<mpsc::Receiver<Callback>>,
    lifecycle_rx: Mutex<mpsc::Receiver<Callback>>,
    task: Mutex<Option<tokio::task::JoinHandle<Result<()>>>>,
    cancel: CancellationToken,
}

impl Drop for NativeRunner {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

impl NativeRunner {
    fn start(definitions: String, options: String) -> Result<Self, Error> {
        let definitions: HashMap<String, Value> =
            serde_json::from_str(&definitions).map_err(error)?;
        let options = parse(&options)?;
        let (tx, rx) = mpsc::sync_channel(CALLBACK_CAPACITY);
        let (lifecycle_tx, lifecycle_rx) = mpsc::sync_channel(CALLBACK_CAPACITY);
        let mut registry = rivetkit_core::CoreRegistry::new();
        for (name, definition) in definitions.iter() {
            let mut config = rivetkit::ActorConfig {
                has_state: true,
                has_database: true,
                remote_sqlite: true,
                actions: definition["actions"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|name| rivetkit_core::ActionDefinition {
                        name: name.as_str().unwrap().to_owned(),
                    })
                    .collect(),
                ..Default::default()
            };
            if let Some(ms) = definition["sleep_timeout_ms"].as_u64() {
                config.sleep_timeout = Duration::from_millis(ms);
            }
            if let Some(ms) = definition["state_save_interval_ms"].as_u64() {
                config.state_save_interval = Duration::from_millis(ms);
            }
            let tx = tx.clone();
            let lifecycle_tx = lifecycle_tx.clone();
            let definition = Arc::new(definition.clone());
            registry.register(
                name,
                ActorFactory::new_with_manual_startup_ready(config, move |start| {
                    let bridge = Arc::new(Bridge {
                        tx: tx.clone(),
                        lifecycle_tx: lifecycle_tx.clone(),
                        definition: definition.clone(),
                        state: Mutex::new(Value::Null),
                        finished: AtomicBool::new(false),
                    });
                    Box::pin(async move {
                        let _activation = ActivationGuard(bridge.clone());
                        bridge.run(start).await
                    })
                }),
            );
        }
        let mut config = rivetkit::ServeConfig::from_env().map_err(error)?;
        if let Some(v) = options["endpoint"].as_str() {
            config.endpoint = v.to_owned();
            config.engine_spawn = rivetkit::EngineSpawnMode::Never;
        }
        if let Some(v) = options["token"].as_str() {
            config.token = Some(v.to_owned());
        }
        if let Some(v) = options["namespace"].as_str() {
            config.namespace = v.to_owned();
        }
        if let Some(v) = options["pool"].as_str() {
            config.pool_name = v.to_owned();
        }
        let cancel = CancellationToken::new();
        let shutdown = cancel.clone();
        let task =
            runtime().spawn(async move { registry.serve_with_config(config, shutdown).await });
        Ok(Self {
            rx: Mutex::new(rx),
            lifecycle_rx: Mutex::new(lifecycle_rx),
            task: Mutex::new(Some(task)),
            cancel,
        })
    }

    fn poll(&self) -> Option<Callback> {
        without_gvl(|| {
            if let Ok(callback) = self.lifecycle_rx.lock().unwrap().try_recv() {
                return Some(callback);
            }
            self.rx
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_millis(100))
                .ok()
        })
    }
    fn finished(&self) -> bool {
        self.task
            .lock()
            .unwrap()
            .as_ref()
            .is_none_or(|task| task.is_finished())
    }
    fn finish(&self) -> Result<(), Error> {
        let task = self.task.lock().unwrap().take();
        if let Some(task) = task {
            wait(async { task.await? })?;
        }
        Ok(())
    }
    fn stop(&self) {
        self.cancel.cancel();
    }
    fn abort(&self) {
        self.stop();
        if let Some(task) = self.task.lock().unwrap().take() {
            task.abort();
        }
        for rx in [&self.rx, &self.lifecycle_rx] {
            while let Ok(callback) = rx.lock().unwrap().try_recv() {
                callback.cancel();
            }
        }
    }
}

#[magnus::wrap(class = "Rivet::NativeContext", free_immediately, size)]
pub struct NativeContext(pub Ctx<RubyActor>, Arc<Bridge>);

impl NativeContext {
    fn metadata(&self) -> String {
        let key: Vec<Value> = self
            .0
            .key()
            .iter()
            .map(|segment| match segment {
                rivetkit::ActorKeySegment::String(v) => json!(v),
                rivetkit::ActorKeySegment::Number(v) => json!(v),
            })
            .collect();
        json!({"id": self.0.actor_id(), "name": self.0.name(), "key": key, "region": self.0.region(), "activation": self.0.inner().instance_key().to_string()}).to_string()
    }
    fn finished(&self) -> bool {
        self.1.finished.load(Ordering::Acquire)
    }
    fn state(&self) -> String {
        self.1.state.lock().unwrap().to_string()
    }
    fn set_state(&self, json: String) -> Result<(), Error> {
        *self.1.state.lock().unwrap() = parse(&json)?;
        self.0.inner().request_save(Default::default());
        Ok(())
    }
    fn broadcast(&self, name: String, json: String) -> Result<(), Error> {
        self.0.broadcast(&name, &parse(&json)?).map_err(error)
    }
    fn sleep(&self) -> Result<(), Error> {
        self.0.sleep().map_err(error)
    }
    fn destroy(&self) -> Result<(), Error> {
        self.0.destroy().map_err(error)
    }
    fn aborted(&self) -> bool {
        self.0.aborted()
    }
    fn keep_awake(&self) -> Result<magnus::Value, Error> {
        let _region = self.0.keep_awake_region();
        Ruby::get().expect("Ruby thread with GVL").yield_values(())
    }
    fn connections(&self) -> magnus::RArray {
        let ruby = Ruby::get().expect("Ruby thread with GVL");
        ruby.ary_from_iter(self.0.conns_vec().into_iter().map(NativeConnection))
    }

    fn sql(&self, sql: String, params: String) -> Result<String, Error> {
        let params = crate::sql::params(&params)?;
        let value = wait(self.0.sql().execute(sql, Some(params)))?;
        Ok(crate::sql::result(
            value.columns,
            value.rows,
            value.changes,
            value.last_insert_row_id,
        ))
    }

    fn begin_sql(&self, timeout_ms: u64) -> Result<crate::sql::NativeTransaction, Error> {
        crate::sql::NativeTransaction::begin(self.0.sql(), timeout_ms)
    }

    fn kv_get(&self, key: String) -> Result<Option<String>, Error> {
        #[allow(deprecated)]
        let value = wait(self.0.kv().get(key.as_bytes()))?;
        value
            .map(|bytes| String::from_utf8(bytes).map_err(error))
            .transpose()
    }
    fn kv_put(&self, key: String, value: String) -> Result<(), Error> {
        #[allow(deprecated)]
        wait(self.0.kv().put(key.as_bytes(), value.as_bytes()))
    }
    fn kv_delete(&self, key: String) -> Result<(), Error> {
        #[allow(deprecated)]
        wait(self.0.kv().delete(key.as_bytes()))
    }
    fn schedule(&self, delay_ms: u64, name: String, args: String) -> Result<String, Error> {
        let bytes = encode(&parse(&args)?).map_err(error)?;
        wait(
            self.0
                .schedule()
                .after(Duration::from_millis(delay_ms), &name, &bytes),
        )
    }
    fn every(
        &self,
        name: String,
        interval_ms: i64,
        action: String,
        args: String,
    ) -> Result<(), Error> {
        let bytes = encode(&parse(&args)?).map_err(error)?;
        wait(
            self.0
                .inner()
                .cron_every(&name, interval_ms, &action, &bytes, None),
        )
    }
    fn cancel_every(&self, name: String) -> Result<bool, Error> {
        wait(self.0.inner().cron_delete(&name))
    }
    fn queue_send(&self, name: String, body: String) -> Result<u64, Error> {
        let body = encode(&parse(&body)?).map_err(error)?;
        Ok(wait(self.0.inner().queue().send(&name, &body))?.id)
    }
    fn queue_next(&self, names: Vec<String>, timeout_ms: u64) -> Result<Option<String>, Error> {
        let opts = rivetkit_core::QueueNextOpts {
            names: Some(names),
            timeout: Some(Duration::from_millis(timeout_ms)),
            ..Default::default()
        };
        wait(self.0.inner().queue().next(opts))?.map(|message| {
            Ok(json!({"id": message.id, "name": message.name, "body": decode(&message.body).map_err(error)?, "created_at": message.created_at}).to_string())
        }).transpose()
    }
}

#[magnus::wrap(class = "Rivet::NativeConnection", free_immediately, size)]
pub struct NativeConnection(pub ConnCtx<RubyActor>);

impl NativeConnection {
    fn id(&self) -> String {
        self.0.id().to_owned()
    }
    fn params(&self) -> Result<String, Error> {
        Ok(self.0.params().map_err(error)?.to_string())
    }
    fn state(&self) -> Result<String, Error> {
        Ok(decode(&self.0.inner().state()).map_err(error)?.to_string())
    }
    fn set_state(&self, json: String) -> Result<(), Error> {
        self.0
            .inner()
            .set_state(encode(&parse(&json)?).map_err(error)?);
        Ok(())
    }
    fn send(&self, name: String, json: String) -> Result<(), Error> {
        self.0.send(&name, &parse(&json)?).map_err(error)
    }
    fn disconnect(&self) -> Result<(), Error> {
        wait(self.0.disconnect(None))
    }
}

pub fn init(ruby: &Ruby, module: magnus::RModule) -> Result<(), Error> {
    use magnus::{function, method};
    let runner = module.define_class("NativeRunner", ruby.class_object())?;
    runner.define_singleton_method("start", function!(NativeRunner::start, 2))?;
    runner.define_method("poll", method!(NativeRunner::poll, 0))?;
    runner.define_method("finished?", method!(NativeRunner::finished, 0))?;
    runner.define_method("finish", method!(NativeRunner::finish, 0))?;
    runner.define_method("stop", method!(NativeRunner::stop, 0))?;
    runner.define_method("abort", method!(NativeRunner::abort, 0))?;
    let callback = module.define_class("NativeCallback", ruby.class_object())?;
    callback.define_method("kind", method!(Callback::kind, 0))?;
    callback.define_method("data", method!(Callback::data, 0))?;
    callback.define_method("context", method!(Callback::context, 0))?;
    callback.define_method("connection", method!(Callback::connection, 0))?;
    callback.define_method("active?", method!(Callback::active, 0))?;
    callback.define_method("lane", method!(Callback::lane, 0))?;
    callback.define_method("cancel", method!(Callback::cancel, 0))?;
    callback.define_method("reject", method!(Callback::reject, 1))?;
    callback.define_method("reply", method!(Callback::reply, 2))?;
    let context = module.define_class("NativeContext", ruby.class_object())?;
    context.define_method("metadata", method!(NativeContext::metadata, 0))?;
    context.define_method("finished?", method!(NativeContext::finished, 0))?;
    context.define_method("state", method!(NativeContext::state, 0))?;
    context.define_method("state=", method!(NativeContext::set_state, 1))?;
    context.define_method("broadcast", method!(NativeContext::broadcast, 2))?;
    context.define_method("sleep", method!(NativeContext::sleep, 0))?;
    context.define_method("destroy", method!(NativeContext::destroy, 0))?;
    context.define_method("aborted?", method!(NativeContext::aborted, 0))?;
    context.define_method("keep_awake", method!(NativeContext::keep_awake, 0))?;
    context.define_method("connections", method!(NativeContext::connections, 0))?;
    context.define_method("sql", method!(NativeContext::sql, 2))?;
    context.define_method("begin_sql", method!(NativeContext::begin_sql, 1))?;
    context.define_method("kv_get", method!(NativeContext::kv_get, 1))?;
    context.define_method("kv_put", method!(NativeContext::kv_put, 2))?;
    context.define_method("kv_delete", method!(NativeContext::kv_delete, 1))?;
    context.define_method("schedule", method!(NativeContext::schedule, 3))?;
    context.define_method("every", method!(NativeContext::every, 4))?;
    context.define_method("cancel_every", method!(NativeContext::cancel_every, 1))?;
    context.define_method("queue_send", method!(NativeContext::queue_send, 2))?;
    context.define_method("queue_next", method!(NativeContext::queue_next, 2))?;
    let conn = module.define_class("NativeConnection", ruby.class_object())?;
    conn.define_method("id", method!(NativeConnection::id, 0))?;
    conn.define_method("params", method!(NativeConnection::params, 0))?;
    conn.define_method("state", method!(NativeConnection::state, 0))?;
    conn.define_method("state=", method!(NativeConnection::set_state, 1))?;
    conn.define_method("send_event", method!(NativeConnection::send, 2))?;
    conn.define_method("disconnect", method!(NativeConnection::disconnect, 0))?;
    Ok(())
}
