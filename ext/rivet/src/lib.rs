use magnus::{Error, Ruby};

mod actor;
mod client;
mod runtime;
mod sql;

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("Rivet")?;
    actor::init(ruby, module)?;
    client::init(ruby, module)?;
    sql::init(ruby, module)?;
    Ok(())
}
