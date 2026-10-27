use std::sync::{Mutex, mpsc};
use std::time::Duration;

use magnus::{Error, Ruby, function, method, prelude::*};
use rivetkit::client::{
    Client, ClientConfig, CreateOptions, GetOptions, GetOrCreateOptions, SendAndWaitOpts, SendOpts,
};
use serde_json::{Value, json};

use crate::runtime::{error, parse, runtime, wait, without_gvl};

#[magnus::wrap(class = "Rivet::NativeClient", free_immediately, size)]
pub struct NativeClient(Client);

impl NativeClient {
    fn new(endpoint: String, options: String) -> Result<Self, Error> {
        let options = parse(&options)?;
        let mut config = ClientConfig::new(endpoint);
        if let Some(v) = options["token"].as_str() {
            config = config
                .token(v)
                .header("Authorization", format!("Bearer {v}"));
        }
        if let Some(v) = options["namespace"].as_str() {
            config = config.namespace(v);
        }
        if let Some(v) = options["pool"].as_str() {
            config = config.pool_name(v);
        }
        let _guard = runtime().enter();
        Ok(Self(Client::new(config)))
    }

    fn handle(
        &self,
        mode: String,
        name: String,
        key: Vec<String>,
        options: String,
    ) -> Result<NativeHandle, Error> {
        let options = parse(&options)?;
        let params = options.get("params").cloned();
        let input = options.get("input").cloned();
        let pool_name = options["pool"].as_str().map(str::to_owned);
        let region = options["region"].as_str().map(str::to_owned);
        let handle = match mode.as_str() {
            "get_or_create" => self
                .0
                .get_or_create(
                    &name,
                    key,
                    GetOrCreateOptions {
                        params,
                        create_with_input: input,
                        create_in_region: region,
                        pool_name,
                    },
                )
                .map_err(error)?,
            "get" => self
                .0
                .get(&name, key, GetOptions { params })
                .map_err(error)?,
            "get_for_id" => self
                .0
                .get_for_id(&name, &key[0], GetOptions { params })
                .map_err(error)?,
            "create" => wait(self.0.create(
                &name,
                key,
                CreateOptions {
                    params,
                    input,
                    region,
                    pool_name,
                },
            ))?,
            _ => return Err(error("unknown handle mode")),
        };
        Ok(NativeHandle(handle))
    }
}

#[magnus::wrap(class = "Rivet::NativeHandle", free_immediately, size)]
pub struct NativeHandle(rivetkit::client::handle::ActorHandle);

impl NativeHandle {
    fn action(&self, name: String, args: String, timeout_ms: u64) -> Result<String, Error> {
        let args: Vec<Value> = serde_json::from_str(&args).map_err(error)?;
        Ok(wait(async {
            tokio::time::timeout(
                Duration::from_millis(timeout_ms),
                self.0.action(&name, args),
            )
            .await?
        })?
        .to_string())
    }
    fn resolve(&self) -> Result<String, Error> {
        wait(self.0.resolve())
    }
    fn connect(&self) -> NativeClientConnection {
        let _guard = runtime().enter();
        NativeClientConnection(self.0.connect())
    }
    fn send(&self, name: String, body: String) -> Result<(), Error> {
        wait(self.0.send(&name, parse(&body)?, SendOpts::default()))
    }
    fn send_and_wait(&self, name: String, body: String, timeout_ms: u64) -> Result<String, Error> {
        let opts = SendAndWaitOpts {
            timeout: Some(Duration::from_millis(timeout_ms)),
        };
        let result = wait(self.0.send_and_wait(&name, parse(&body)?, opts))?;
        Ok(json!({"status": format!("{:?}", result.status).to_lowercase(), "response": result.response}).to_string())
    }

    fn fetch(&self, path: String, options: String) -> Result<String, Error> {
        let options = parse(&options)?;
        let method = options["method"]
            .as_str()
            .unwrap_or("GET")
            .parse()
            .map_err(error)?;
        let headers: std::collections::HashMap<String, String> =
            serde_json::from_value(options["headers"].clone()).map_err(error)?;
        let mut header_map = reqwest::header::HeaderMap::new();
        for (name, value) in headers {
            header_map.insert(
                name.parse::<reqwest::header::HeaderName>().map_err(error)?,
                value.parse().map_err(error)?,
            );
        }
        let body: Option<Vec<u8>> =
            serde_json::from_value(options["body"].clone()).map_err(error)?;
        wait(async {
            let response = self
                .0
                .fetch(&path, method, header_map, body.map(Into::into))
                .await?;
            let status = response.status().as_u16();
            let headers: std::collections::HashMap<String, String> = response
                .headers()
                .iter()
                .map(|(name, value)| {
                    (
                        name.to_string(),
                        String::from_utf8_lossy(value.as_bytes()).into_owned(),
                    )
                })
                .collect();
            let body = response.bytes().await?.to_vec();
            Ok(json!({"status": status, "headers": headers, "body": body}).to_string())
        })
    }
}

#[magnus::wrap(class = "Rivet::NativeClientConnection", free_immediately, size)]
pub struct NativeClientConnection(rivetkit::client::connection::ActorConnection);

impl NativeClientConnection {
    fn action(&self, name: String, args: String, timeout_ms: u64) -> Result<String, Error> {
        let args: Vec<Value> = serde_json::from_str(&args).map_err(error)?;
        Ok(wait(async {
            tokio::time::timeout(
                Duration::from_millis(timeout_ms),
                self.0.action(&name, args),
            )
            .await?
        })?
        .to_string())
    }
    fn subscribe(&self, name: String) -> NativeSubscription {
        let (tx, rx) = mpsc::channel();
        let handle = without_gvl(|| {
            runtime().block_on(self.0.on_event(&name, move |args| {
                let _ = tx.send(json!(args).to_string());
            }))
        });
        NativeSubscription {
            handle,
            rx: Mutex::new(rx),
        }
    }
    fn close(&self) {
        without_gvl(|| runtime().block_on(self.0.dispose()));
    }
    fn status(&self) -> String {
        format!("{:?}", self.0.conn_status()).to_lowercase()
    }
}

#[magnus::wrap(class = "Rivet::NativeSubscription", free_immediately, size)]
pub struct NativeSubscription {
    handle: rivetkit::client::SubscriptionHandle,
    rx: Mutex<mpsc::Receiver<String>>,
}

impl NativeSubscription {
    fn poll(&self, timeout_ms: u64) -> Option<String> {
        without_gvl(|| {
            self.rx
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_millis(timeout_ms))
                .ok()
        })
    }
    fn unsubscribe(&self) {
        without_gvl(|| runtime().block_on(self.handle.unsubscribe()));
    }
}

pub fn init(ruby: &Ruby, module: magnus::RModule) -> Result<(), Error> {
    let client = module.define_class("NativeClient", ruby.class_object())?;
    client.define_singleton_method("new", function!(NativeClient::new, 2))?;
    client.define_method("handle", method!(NativeClient::handle, 4))?;
    let handle = module.define_class("NativeHandle", ruby.class_object())?;
    handle.define_method("action", method!(NativeHandle::action, 3))?;
    handle.define_method("resolve", method!(NativeHandle::resolve, 0))?;
    handle.define_method("connect", method!(NativeHandle::connect, 0))?;
    handle.define_method("send_message", method!(NativeHandle::send, 2))?;
    handle.define_method("send_and_wait", method!(NativeHandle::send_and_wait, 3))?;
    handle.define_method("fetch", method!(NativeHandle::fetch, 2))?;
    let conn = module.define_class("NativeClientConnection", ruby.class_object())?;
    conn.define_method("action", method!(NativeClientConnection::action, 3))?;
    conn.define_method("subscribe", method!(NativeClientConnection::subscribe, 1))?;
    conn.define_method("close", method!(NativeClientConnection::close, 0))?;
    conn.define_method("status", method!(NativeClientConnection::status, 0))?;
    let sub = module.define_class("NativeSubscription", ruby.class_object())?;
    sub.define_method("poll", method!(NativeSubscription::poll, 1))?;
    sub.define_method("unsubscribe", method!(NativeSubscription::unsubscribe, 0))?;
    Ok(())
}
