use std::ffi::c_void;
use std::future::Future;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::OnceLock;

use magnus::{Error, Ruby};
use tokio::runtime::Runtime;

pub fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("create Rivet runtime")
    })
}

pub fn error(error: impl std::fmt::Display) -> Error {
    let ruby = Ruby::get().expect("Ruby thread with GVL");
    Error::new(ruby.exception_runtime_error(), error.to_string())
}

pub fn without_gvl<F: FnOnce() -> T, T>(f: F) -> T {
    struct Call<F, T> {
        f: Option<F>,
        result: Option<std::thread::Result<T>>,
    }

    unsafe extern "C" fn invoke<F: FnOnce() -> T, T>(ptr: *mut c_void) -> *mut c_void {
        let call = unsafe { &mut *ptr.cast::<Call<F, T>>() };
        call.result = Some(catch_unwind(AssertUnwindSafe(call.f.take().unwrap())));
        std::ptr::null_mut()
    }

    let mut call = Call {
        f: Some(f),
        result: None,
    };
    // No Ruby values or Ruby API calls may cross this boundary.
    unsafe {
        rb_sys::rb_thread_call_without_gvl(
            Some(invoke::<F, T>),
            (&mut call as *mut Call<F, T>).cast(),
            None,
            std::ptr::null_mut(),
        );
    }
    match call.result.expect("native call completed") {
        Ok(result) => result,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

pub fn wait<T>(future: impl Future<Output = anyhow::Result<T>>) -> Result<T, Error> {
    without_gvl(|| runtime().block_on(future)).map_err(|e| error(format!("{e:#}")))
}

pub fn parse(json: &str) -> Result<serde_json::Value, Error> {
    serde_json::from_str(json).map_err(error)
}

pub fn encode(value: &serde_json::Value) -> anyhow::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    ciborium::into_writer(value, &mut bytes)?;
    Ok(bytes)
}

pub fn decode(bytes: &[u8]) -> anyhow::Result<serde_json::Value> {
    Ok(ciborium::from_reader(bytes)?)
}
