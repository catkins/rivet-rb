use std::ffi::c_void;
use std::future::Future;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::OnceLock;

use magnus::{
    Error, ExceptionClass, Float, Integer, RArray, RHash, RModule, RString, Ruby, Symbol,
    prelude::*,
};
use serde_json::Value;
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

fn exception(name: &str) -> ExceptionClass {
    let ruby = Ruby::get().expect("Ruby thread with GVL");
    ruby.class_object()
        .const_get::<_, RModule>("Rivet")
        .expect("Rivet module")
        .const_get(name)
        .expect("Rivet exception class")
}

pub fn error(error: impl std::fmt::Display) -> Error {
    Error::new(exception("Error"), error.to_string())
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

pub fn deadline<T>(
    timeout_ms: u64,
    future: impl Future<Output = anyhow::Result<T>>,
) -> Result<T, Error> {
    match without_gvl(|| {
        runtime().block_on(async {
            tokio::time::timeout(std::time::Duration::from_millis(timeout_ms), future).await
        })
    }) {
        Ok(result) => result.map_err(|e| error(format!("{e:#}"))),
        Err(_) => Err(Error::new(exception("TimeoutError"), "operation timed out")),
    }
}

pub fn from_ruby(value: magnus::Value) -> Result<Value, Error> {
    fn convert(ruby: &Ruby, value: magnus::Value, depth: usize) -> Result<Value, Error> {
        if depth > 100 {
            return Err(Error::new(
                ruby.exception_arg_error(),
                "value nesting exceeds 100 levels (or contains a cycle)",
            ));
        }
        if value.is_nil() {
            Ok(Value::Null)
        } else if magnus::value::Qtrue::from_value(value).is_some() {
            Ok(Value::Bool(true))
        } else if magnus::value::Qfalse::from_value(value).is_some() {
            Ok(Value::Bool(false))
        } else if let Some(integer) = Integer::from_value(value) {
            if let Ok(number) = integer.to_i64() {
                Ok(Value::from(number))
            } else if let Ok(number) = integer.to_u64() {
                Ok(Value::from(number))
            } else {
                Err(Error::new(
                    ruby.exception_range_error(),
                    "JSON integers must fit in signed or unsigned 64 bits; use a decimal string",
                ))
            }
        } else if let Some(float) = Float::from_value(value) {
            serde_json::Number::from_f64(float.to_f64())
                .map(Value::Number)
                .ok_or_else(|| Error::new(ruby.exception_arg_error(), "floats must be finite"))
        } else if let Some(string) = RString::from_value(value) {
            Ok(Value::String(string.to_string()?))
        } else if let Some(symbol) = Symbol::from_value(value) {
            Ok(Value::String(symbol.name()?.into_owned()))
        } else if let Some(array) = RArray::from_value(value) {
            (0..array.len())
                .map(|index| convert(ruby, array.entry(index as isize)?, depth + 1))
                .collect::<Result<Vec<_>, _>>()
                .map(Value::Array)
        } else if let Some(hash) = RHash::from_value(value) {
            let mut object = serde_json::Map::new();
            hash.foreach(|key: magnus::Value, child: magnus::Value| {
                let key: RString = key.funcall("to_s", ())?;
                object.insert(key.to_string()?, convert(ruby, child, depth + 1)?);
                Ok(magnus::r_hash::ForEach::Continue)
            })?;
            Ok(Value::Object(object))
        } else {
            Err(Error::new(
                ruby.exception_type_error(),
                "expected nil, boolean, integer, float, string, symbol, array or hash; convert application objects explicitly",
            ))
        }
    }
    convert(&Ruby::get().expect("Ruby thread with GVL"), value, 0)
}

pub fn to_ruby(value: &Value) -> Result<magnus::Value, Error> {
    let ruby = Ruby::get().expect("Ruby thread with GVL");
    Ok(match value {
        Value::Null => ruby.qnil().as_value(),
        Value::Bool(value) => ruby.into_value(*value),
        Value::Number(value) => {
            if let Some(value) = value.as_i64() {
                ruby.into_value(value)
            } else if let Some(value) = value.as_u64() {
                ruby.into_value(value)
            } else {
                ruby.into_value(value.as_f64().unwrap())
            }
        }
        Value::String(value) => ruby.str_new(value).as_value(),
        Value::Array(values) => {
            let array = ruby.ary_new_capa(values.len());
            for value in values {
                array.push(to_ruby(value)?)?;
            }
            array.as_value()
        }
        Value::Object(values) => {
            let hash = ruby.hash_new();
            for (key, value) in values {
                hash.aset(ruby.str_new(key), to_ruby(value)?)?;
            }
            hash.as_value()
        }
    })
}

pub fn encode(value: &serde_json::Value) -> anyhow::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    ciborium::into_writer(value, &mut bytes)?;
    Ok(bytes)
}

pub fn decode(bytes: &[u8]) -> anyhow::Result<serde_json::Value> {
    Ok(ciborium::from_reader(bytes)?)
}
