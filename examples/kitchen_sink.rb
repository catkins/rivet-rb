require "rivet"
require "securerandom"

class KitchenSink < Rivet::Actor
  configure sleep_timeout: 60, state_save_interval: 0.1
  state { |_ctx, input| {"input" => input, "created" => 0, "starts" => 0, "sleeps" => 0} }

  on_create do |ctx|
    ctx.update_state { |state| state["created"] += 1 }
  end

  on_start do |ctx|
    @activation = SecureRandom.hex(8)
    ctx.update_state { |state| state["starts"] += 1 }
    ctx.sql.execute("CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, value TEXT NOT NULL)")
  end

  on_sleep do |ctx|
    ctx.update_state { |state| state["sleeps"] += 1 }
  end

  create_conn_state { |_ctx, params| {"user" => params&.fetch("user", "anonymous"), "calls" => 0} }

  on_fetch do |_ctx, request|
    [201, {"content-type" => "application/octet-stream", "x-method" => request.method}, [request.body.reverse]]
  end

  action :echo do |_ctx, *args|
    args
  end

  action :info do |ctx|
    {"id" => ctx.id, "name" => ctx.name, "key" => ctx.key, "region" => ctx.region,
     "state" => ctx.state, "activation" => @activation}
  end

  action :replace do |ctx, value|
    ctx.state = value
    ctx.state
  end

  action :sql_put do |ctx, id, value|
    ctx.sql.execute("INSERT INTO entries (id, value) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET value = excluded.value", id, value)
  end

  action :sql_entries do |ctx|
    ctx.sql.query("SELECT id, value FROM entries ORDER BY id")
  end

  action :sql_transaction do |ctx, should_fail|
    ctx.sql.transaction do |tx|
      tx.execute("INSERT INTO entries VALUES (?, ?)", "transaction", "committed")
      raise ArgumentError, "roll back" if should_fail
      tx.query("SELECT value FROM entries WHERE id = ?", "transaction")
    end
  end

  action :sql_types do |ctx|
    ctx.sql.query("SELECT ? AS integer_value, ? AS float_value, ? AS null_value, ? AS bool_value, ? AS blob_value",
      -9_007_199_254_740_991, 3.25, nil, false, "\x00\xff\x41".b
    ).map { |row| row.merge("blob_value" => row.fetch("blob_value").bytes) }
  end

  action :kv_put do |ctx, key, value|
    ctx.kv[key] = value
  end

  action :kv_get do |ctx, key|
    ctx.kv[key]
  end

  action :kv_delete do |ctx, key|
    ctx.kv.delete(key)
  end

  action :connection_info do |ctx|
    conn = ctx.connection
    state = conn.state
    state["calls"] += 1
    conn.state = state
    {"id" => conn.id, "params" => conn.params, "state" => conn.state,
     "connections" => ctx.connections.map(&:id)}
  end

  action :emit do |ctx, name, *args|
    ctx.broadcast(name, *args)
  end

  action :whisper do |ctx, name, *args|
    ctx.connection.emit(name, *args)
  end

  action :enqueue do |ctx, name, body|
    ctx.queue.send(name, body)
  end

  action :dequeue do |ctx, name|
    ctx.queue.next(name)
  end

  queue :double do |_ctx, body|
    body.fetch("value") * 2
  end

  action :schedule do |ctx, delay, value|
    ctx.after(delay, :kv_put, "scheduled", value)
  end

  action :sleep_now do |ctx|
    ctx.sleep
    nil
  end

  action :destroy_now do |ctx|
    ctx.destroy
    nil
  end

  action :fail do |_ctx|
    raise ArgumentError, "deliberate failure"
  end

  action :blob_put do |ctx, key, body|
    object_key = "#{ctx.id}/#{key}"
    response = s3.put_object(bucket: ENV.fetch("S3_BUCKET"), key: object_key, body: body)
    {"key" => object_key, "etag" => response.etag}
  end

  action :blob_get do |ctx, key|
    s3.get_object(bucket: ENV.fetch("S3_BUCKET"), key: "#{ctx.id}/#{key}").body.read.force_encoding(Encoding::UTF_8)
  end

  private

  def s3
    require "aws-sdk-s3"
    @s3 ||= Aws::S3::Client.new(
      endpoint: ENV.fetch("S3_ENDPOINT"),
      region: ENV.fetch("AWS_REGION", "us-east-1"),
      force_path_style: true
    )
  end
end
