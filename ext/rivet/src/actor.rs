use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use anyhow::{Result, anyhow};
use async_trait::async_trait;
use magnus::{Error, Ruby, prelude::*};
use rivetkit::{ActionSet, Actor, ConnCtx, Ctx, QueueSet};
use serde_json::{Value, json};
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

use crate::runtime::{decode, encode, error, parse, runtime, wait, without_gvl};

tokio::task_local! { static BRIDGE: Arc<Bridge>; }

pub struct Bridge {
    tx: mpsc::Sender<Callback>,
    definitions: HashMap<String, Value>,
}

impl Bridge {
    async fn call(
        &self,
        ctx: Ctx<RubyActor>,
        kind: &str,
        data: Value,
        conn: Option<ConnCtx<RubyActor>>,
    ) -> Result<Value> {
        let (tx, rx) = oneshot::channel();
        self.tx
            .send(Callback {
                ctx,
                kind: kind.to_owned(),
                data: data.to_string(),
                conn,
                reply: Mutex::new(Some(tx)),
            })
            .map_err(|_| anyhow!("Ruby dispatcher stopped"))?;
        rx.await.map_err(|_| anyhow!("Ruby callback dropped"))?
    }
}

pub struct RubyActor {
    bridge: Arc<Bridge>,
}

#[async_trait]
impl Actor for RubyActor {
    type State = Value;
    type Input = Value;
    type Actions = Self;
    type Events = ();
    type Queue = Self;
    type ConnParams = Value;
    type ConnState = Value;
    type Action = rivetkit::Raw;

    async fn create_state(ctx: &Ctx<Self>, input: Value) -> Result<Value> {
        BRIDGE
            .get()
            .call(ctx.clone(), "create_state", input, None)
            .await
    }

    async fn create(_ctx: &Ctx<Self>) -> Result<Self> {
        Ok(Self {
            bridge: BRIDGE.get(),
        })
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

    async fn create_conn_state(self: Arc<Self>, ctx: Ctx<Self>, params: Value) -> Result<Value> {
        self.bridge
            .call(ctx, "create_conn_state", params, None)
            .await
    }

    async fn on_before_connect(self: Arc<Self>, ctx: Ctx<Self>, params: &Value) -> Result<()> {
        self.bridge
            .call(ctx, "on_before_connect", params.clone(), None)
            .await
            .map(|_| ())
    }

    async fn on_connect(self: Arc<Self>, ctx: Ctx<Self>, conn: ConnCtx<Self>) -> Result<()> {
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
        if !actor.bridge.definitions[ctx.name()]["actions"]
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

impl QueueSet<RubyActor> for RubyActor {
    fn entries() -> Vec<rivetkit::QueueEntry<Self>> {
        Vec::new()
    }

    fn dispatch(
        actor: Arc<Self>,
        ctx: Ctx<Self>,
        name: &str,
        body: &[u8],
    ) -> Option<Pin<Box<dyn Future<Output = Result<Option<Vec<u8>>>> + Send>>> {
        if !actor.bridge.definitions[ctx.name()]["queues"]
            .as_array()?
            .iter()
            .any(|v| v == name)
        {
            return None;
        }
        let name = name.to_owned();
        let body = body.to_vec();
        Some(Box::pin(async move {
            let data = json!({"name": name, "body": decode(&body)?});
            let result = actor.bridge.call(ctx, "queue", data, None).await?;
            Ok(Some(encode(&result)?))
        }))
    }
}

#[magnus::wrap(class = "Rivet::NativeCallback", free_immediately, size)]
pub struct Callback {
    ctx: Ctx<RubyActor>,
    kind: String,
    data: String,
    conn: Option<ConnCtx<RubyActor>>,
    reply: Mutex<Option<oneshot::Sender<Result<Value>>>>,
}

impl Callback {
    fn kind(&self) -> String {
        self.kind.clone()
    }
    fn data(&self) -> String {
        self.data.clone()
    }
    fn context(&self) -> NativeContext {
        NativeContext(self.ctx.clone())
    }
    fn connection(&self) -> Option<NativeConnection> {
        self.conn
            .clone()
            .or_else(|| self.ctx.conn().cloned())
            .map(NativeConnection)
    }
    fn active(&self) -> bool {
        self.reply
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
        let (tx, rx) = mpsc::channel();
        let bridge = Arc::new(Bridge { tx, definitions });
        let mut registry = rivetkit::Registry::new();
        for (name, definition) in &bridge.definitions {
            let mut config = rivetkit::ActorConfig::default();
            config.has_state = true;
            config.has_database = true;
            config.remote_sqlite = true;
            config.actions = definition["actions"]
                .as_array()
                .unwrap()
                .iter()
                .map(|name| rivetkit_core::ActionDefinition {
                    name: name.as_str().unwrap().to_owned(),
                })
                .collect();
            if let Some(ms) = definition["sleep_timeout_ms"].as_u64() {
                config.sleep_timeout = Duration::from_millis(ms);
            }
            if let Some(ms) = definition["state_save_interval_ms"].as_u64() {
                config.state_save_interval = Duration::from_millis(ms);
            }
            let bridge = bridge.clone();
            #[allow(deprecated)]
            registry.register_with::<RubyActor, _, _>(name, config, move |start| {
                let bridge = bridge.clone();
                async move { BRIDGE.scope(bridge, rivetkit::run_actor(start)).await }
            });
        }
        let mut config = rivetkit::ServeConfig::from_env().map_err(error)?;
        if let Some(v) = options["endpoint"].as_str() {
            config.endpoint = v.to_owned();
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
            task: Mutex::new(Some(task)),
            cancel,
        })
    }

    fn poll(&self) -> Option<Callback> {
        without_gvl(|| {
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
}

#[magnus::wrap(class = "Rivet::NativeContext", free_immediately, size)]
pub struct NativeContext(pub Ctx<RubyActor>);

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
        json!({"id": self.0.actor_id(), "name": self.0.name(), "key": key, "region": self.0.region()}).to_string()
    }
    fn state(&self) -> String {
        self.0.state().to_string()
    }
    fn set_state(&self, json: String) -> Result<(), Error> {
        self.0.set_state(parse(&json)?);
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
    fn queue_send(&self, name: String, body: String) -> Result<u64, Error> {
        let body = parse(&body)?;
        Ok(wait(self.0.queue().send(&name, &body))?.id)
    }
    fn queue_next(&self, names: Vec<String>, timeout_ms: u64) -> Result<Option<String>, Error> {
        let opts = rivetkit::QueueNextOpts {
            names: Some(names),
            timeout: Some(Duration::from_millis(timeout_ms)),
            ..Default::default()
        };
        wait(self.0.queue().next(opts))?.map(|message| {
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
        Ok(self.0.state().map_err(error)?.to_string())
    }
    fn set_state(&self, json: String) -> Result<(), Error> {
        self.0.set_state(&parse(&json)?).map_err(error)
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
    let callback = module.define_class("NativeCallback", ruby.class_object())?;
    callback.define_method("kind", method!(Callback::kind, 0))?;
    callback.define_method("data", method!(Callback::data, 0))?;
    callback.define_method("context", method!(Callback::context, 0))?;
    callback.define_method("connection", method!(Callback::connection, 0))?;
    callback.define_method("active?", method!(Callback::active, 0))?;
    callback.define_method("reply", method!(Callback::reply, 2))?;
    let context = module.define_class("NativeContext", ruby.class_object())?;
    context.define_method("metadata", method!(NativeContext::metadata, 0))?;
    context.define_method("state", method!(NativeContext::state, 0))?;
    context.define_method("state=", method!(NativeContext::set_state, 1))?;
    context.define_method("broadcast", method!(NativeContext::broadcast, 2))?;
    context.define_method("sleep", method!(NativeContext::sleep, 0))?;
    context.define_method("destroy", method!(NativeContext::destroy, 0))?;
    context.define_method("aborted?", method!(NativeContext::aborted, 0))?;
    context.define_method("connections", method!(NativeContext::connections, 0))?;
    context.define_method("sql", method!(NativeContext::sql, 2))?;
    context.define_method("begin_sql", method!(NativeContext::begin_sql, 1))?;
    context.define_method("kv_get", method!(NativeContext::kv_get, 1))?;
    context.define_method("kv_put", method!(NativeContext::kv_put, 2))?;
    context.define_method("kv_delete", method!(NativeContext::kv_delete, 1))?;
    context.define_method("schedule", method!(NativeContext::schedule, 3))?;
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
