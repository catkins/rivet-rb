use std::time::Duration;

use magnus::{Error, Ruby, method, prelude::*};
use rivetkit::{BindParam, ColumnValue};
use serde_json::{Value, json};

use crate::runtime::{error, parse, wait};

pub fn params(json: &str) -> Result<Vec<BindParam>, Error> {
    parse(json)?
        .as_array()
        .ok_or_else(|| error("SQL parameters must be an array"))?
        .iter()
        .map(|v| {
            Ok(match v {
                Value::Null => BindParam::Null,
                Value::Bool(v) => BindParam::Integer(i64::from(*v)),
                Value::Number(v) if v.is_i64() => BindParam::Integer(v.as_i64().unwrap()),
                Value::Number(v) if v.is_u64() => {
                    return Err(error("SQL integers must fit in signed 64 bits"));
                }
                Value::Number(v) => BindParam::Float(v.as_f64().unwrap()),
                Value::String(v) => BindParam::Text(v.clone()),
                Value::Object(v) if v.len() == 1 && v.contains_key("blob") => {
                    BindParam::Blob(serde_json::from_value(v["blob"].clone()).map_err(error)?)
                }
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
) -> String {
    let rows: Vec<Vec<Value>> = rows
        .into_iter()
        .map(|row| {
            row.into_iter()
                .map(|v| match v {
                    ColumnValue::Null => Value::Null,
                    ColumnValue::Integer(v) => json!(v),
                    ColumnValue::Float(v) => json!(v),
                    ColumnValue::Text(v) => json!(v),
                    ColumnValue::Blob(v) => json!({"blob": v}),
                })
                .collect()
        })
        .collect();
    json!({"columns": columns, "rows": rows, "changes": changes, "last_insert_row_id": last_insert_row_id}).to_string()
}

#[magnus::wrap(class = "Rivet::NativeTransaction", free_immediately, size)]
pub struct NativeTransaction(pub rivetkit::SqliteTransaction);

impl NativeTransaction {
    pub fn begin(db: &rivetkit::SqliteDb, timeout_ms: u64) -> Result<Self, Error> {
        Ok(Self(wait(db.begin_transaction(Some(
            Duration::from_millis(timeout_ms),
        )))?))
    }

    fn sql(&self, statement: String, json: String) -> Result<String, Error> {
        let value = wait(self.0.execute(statement, Some(params(&json)?)))?;
        Ok(result(
            value.columns,
            value.rows,
            value.changes,
            value.last_insert_row_id,
        ))
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
