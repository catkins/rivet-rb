# SQLite

[README](../README.md) · [API](api.md) · [Development](development.md) · [Concurrency](concurrency.md)

SQL executes in Rivet's **remote engine**, not a local database in the Ruby runner. Extension
availability depends on the engine build and connection settings, not gems installed in the runner.
See the [kitchen-sink example](../examples/kitchen_sink.rb) for usage and the
[durable agent](../examples/durable_agent/README.md) for a SQLite-journaled application.

## Queries and transactions

`ctx.sql.query(sql, *params)` returns an Array of row Hashes. `execute(sql, *params)` returns
`columns`, `rows`, `changes` and `last_insert_row_id`.

Bind nil, booleans (0/1), signed 64-bit integers, floats, UTF-8 text and binary Strings
(`string.b`, SQLite BLOBs). Out-of-range Ruby integer binds raise `RangeError` before native
conversion. Results preserve binary Strings.

`ctx.sql.transaction { |tx| ... }` commits on normal block completion and rolls back on
exceptions or nonlocal exits. **Use the yielded `tx`, not `ctx.sql`, inside a transaction.**
Do not share a transaction between independent operations. Keep local SQL tools short and free
of network I/O; a transaction cannot atomically commit a remote service's write.

BLOB results are binary Ruby Strings inside the actor. Encode arbitrary binary data as Base64
or byte arrays before returning it through [JSON-compatible actions](api.md#value-conversion-and-transport).

## Measured engine features

Reverified through the Ruby binding against the pinned Compose engine/SDK **3.0.6** on
**2026-11-08**, which reported embedded SQLite **3.46.0**. These are observations of that image,
not guarantees for other Rivet deployments or future versions.

| Feature | Observed support |
| --- | --- |
| JSON and SQLite JSONB | JSON functions work; JSONB is an opaque BLOB and can be rebound as a SQL parameter |
| FTS5 full-text search | `MATCH` and `highlight` work; FTS data persists through actor sleep |
| R*Tree spatial index | Spatial filters work; RTree data persists through actor sleep |
| Modern SQL | STRICT tables, generated columns, window functions and `RETURNING` work |
| Transactions | Commit/rollback and persistence through sleep pass |
| Runtime extension loading | `load_extension(...)` is unauthorized, despite the build reporting `ENABLE_LOAD_EXTENSION` |
| Unavailable functions | `vec_version()`, `spatialite_version()`, `sqrt()`, `regexp`, `decimal_add()` and `uuid()` |

Installing a SQLite extension gem in the runner does not load it into the engine. Custom native
extensions need engine-side integration and initialization. The binding exposes no extension-loading
controls, Ruby-defined SQL functions or custom collation registration. RTree is a spatial index,
not evidence that SpatiaLite geometry functions are available.

## Application data types

SQLite stores NULL, INTEGER, REAL, TEXT and BLOB values. Declarations such as `DECIMAL`,
`TIMESTAMP`, `JSON` or `UUID` do not create dedicated storage types. The earlier
`3.0.0-preview.2` probe on 2026-11-07 found that a decimal string inserted into `DECIMAL(20,6)`
became a floating-point REAL; timestamp, JSON and UUID strings remained TEXT. The wrapper does
not automatically convert results into `BigDecimal`, `Time`, parsed JSON or UUID objects.

| Application value | Suggested representation |
| --- | --- |
| Money or exact decimals | Scaled signed 64-bit integers, or decimal strings in TEXT; REAL arithmetic is not exact decimal arithmetic |
| Dates and times | ISO 8601 TEXT or integer timestamps, with application-defined timezone and precision |
| UUIDs | TEXT or 16-byte BLOBs |
| JSON documents | JSON TEXT with explicit Ruby serialization/parsing, or SQLite JSONB as an opaque BLOB |
| Vectors | Packed BLOBs store values but provide no vector indexing or similarity functions |

## Sequel

There is no Sequel adapter. Sequel's standard SQLite adapter opens a local database through the
`sqlite3` gem and cannot be pointed at `ctx.sql` unchanged. A future Rivet adapter could provide
query-building, schema and Ruby type-conversion APIs scoped to an actor's database; it would
not enable missing engine extensions or make SQLite decimal arithmetic exact.
