use std::time::Duration;

use magnus::{Error, RArray, RString, Ruby, encoding::EncodingCapable, method, prelude::*};
use rivetkit::{BindParam, ColumnValue};
use serde_json::Value;

use crate::runtime::{error, from_ruby, wait};

pub fn params(values: RArray) -> Result<Vec<BindParam>, Error> {
    let ruby = Ruby::get().expect("Ruby thread with GVL");
    (0..values.len())
        .map(|index| {
            let value = values.entry(index as isize)?;
            if let Some(string) = RString::from_value(value)
                && string.enc_get() == ruby.ascii8bit_encindex()
            {
                return Ok(BindParam::Blob(unsafe { string.as_slice().to_vec() }));
            }
            Ok(match from_ruby(value)? {
                Value::Null => BindParam::Null,
                Value::Bool(v) => BindParam::Integer(i64::from(v)),
                Value::Number(v) if v.is_i64() => BindParam::Integer(v.as_i64().unwrap()),
                Value::Number(v) if v.is_u64() => {
                    return Err(error("SQL integers must fit in signed 64 bits"));
                }
                Value::Number(v) => BindParam::Float(v.as_f64().unwrap()),
                Value::String(v) => BindParam::Text(v),
                _ => return Err(error("unsupported SQL parameter")),
            })
        })
        .collect()
}

pub fn result(
    columns: Vec<String>,
    rows: Vec<Vec<ColumnValue>>,
    changes: i64,
    last_insert_row_id: Option<i64>,
) -> Result<magnus::Value, Error> {
    let ruby = Ruby::get().expect("Ruby thread with GVL");
    let result = ruby.hash_new();
    let ruby_rows = ruby.ary_new_capa(rows.len());
    for row in rows {
        let ruby_row = ruby.ary_new_capa(row.len());
        for value in row {
            ruby_row.push(match value {
                ColumnValue::Integer(v) => ruby.into_value(v),
                ColumnValue::Float(v) if v.is_finite() => ruby.into_value(v),
                ColumnValue::Null | ColumnValue::Float(_) => ruby.qnil().as_value(),
                ColumnValue::Text(v) => ruby.str_new(&v).as_value(),
                ColumnValue::Blob(v) => ruby.str_from_slice(&v).as_value(),
            })?;
        }
        ruby_rows.push(ruby_row)?;
    }
    result.aset("columns", columns)?;
    result.aset("rows", ruby_rows)?;
    result.aset("changes", changes)?;
    result.aset("last_insert_row_id", last_insert_row_id)?;
    Ok(result.as_value())
}

#[magnus::wrap(class = "Rivet::NativeTransaction", free_immediately, size)]
pub struct NativeTransaction(pub rivetkit::SqliteTransaction);

impl NativeTransaction {
    pub fn begin(db: &rivetkit::SqliteDb, timeout_ms: u64) -> Result<Self, Error> {
        Ok(Self(wait(db.begin_transaction(Some(
            Duration::from_millis(timeout_ms),
        )))?))
    }

    fn sql(&self, statement: String, params_value: RArray) -> Result<magnus::Value, Error> {
        let value = wait(self.0.execute(statement, Some(params(params_value)?)))?;
        result(
            value.columns,
            value.rows,
            value.changes,
            value.last_insert_row_id,
        )
    }
    fn commit(&self) -> Result<(), Error> {
        wait(self.0.commit())
    }
    fn rollback(&self) -> Result<(), Error> {
        wait(self.0.rollback())
    }
}

pub fn init(ruby: &Ruby, module: magnus::RModule) -> Result<(), Error> {
    let tx = module.define_class("NativeTransaction", ruby.class_object())?;
    tx.define_method("sql", method!(NativeTransaction::sql, 2))?;
    tx.define_method("commit", method!(NativeTransaction::commit, 0))?;
    tx.define_method("rollback", method!(NativeTransaction::rollback, 0))?;
    Ok(())
}
