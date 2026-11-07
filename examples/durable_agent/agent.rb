require "rivet"
require_relative "tools"

# One durable text conversation per actor key. See README.md in this directory.
# @api private
class DurableAgent < Rivet::Actor
  configure sleep_timeout: 5

  on_start do |ctx|
    ctx.sql.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS agent_runs (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE,
        prompt TEXT NOT NULL,
        settings TEXT NOT NULL,
        status TEXT NOT NULL,
        retry_at REAL NOT NULL DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0,
        error TEXT
      )
    SQL
    ctx.sql.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS agent_messages (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        run_id TEXT NOT NULL,
        turn INTEGER,
        tool_call_id TEXT,
        payload TEXT NOT NULL,
        UNIQUE(turn, tool_call_id)
      )
    SQL
    ctx.sql.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS agent_tools (
        run_id TEXT NOT NULL,
        turn INTEGER NOT NULL,
        call_id TEXT NOT NULL,
        name TEXT NOT NULL,
        replay TEXT NOT NULL,
        idempotency_key TEXT NOT NULL,
        status TEXT NOT NULL,
        PRIMARY KEY(turn, call_id)
      )
    SQL
    ctx.sql.execute("CREATE TABLE IF NOT EXISTS agent_notes (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    @wake = ::Queue.new
    ctx.every("agent-recovery", 5, :wake)
    @wake << true
  end

  run do |ctx|
    until ctx.aborted?
      next unless @wake.pop(timeout: 0.1)
      ctx.keep_awake { drain(ctx) } unless ctx.aborted?
    end
  end

  action :submit do |ctx, prompt, request_id|
    unless [prompt, request_id].all? { |value| value.is_a?(String) && !value.empty? }
      raise ArgumentError, "prompt and request_id must be nonempty strings"
    end
    ctx.every("agent-recovery", 5, :wake)
    ctx.sql.transaction do |tx|
      existing = tx.query("SELECT prompt FROM agent_runs WHERE id = ?", request_id).first
      raise ArgumentError, "request_id already belongs to another prompt" if existing && existing.fetch("prompt") != prompt
      tx.execute("INSERT OR IGNORE INTO agent_runs (id, prompt, settings, status) VALUES (?, ?, ?, 'queued')",
        request_id, prompt, JSON.generate(settings)
      )
    end
    @wake << true
    {"request_id" => request_id}
  end

  action :snapshot do |ctx|
    ctx.sql.transaction do |tx|
      {
        "actor_id" => ctx.id,
        "runs" => tx.query("SELECT id, status, retry_at, attempts, error FROM agent_runs ORDER BY seq"),
        "messages" => tx.query("SELECT seq, run_id, payload FROM agent_messages ORDER BY seq").map do |row|
          row.merge("message" => JSON.parse(row.fetch("payload"))).reject { |key, _| key == "payload" }
        end,
        "tools" => tx.query("SELECT * FROM agent_tools ORDER BY turn, call_id"),
        "notes" => tx.query("SELECT key, value FROM agent_notes ORDER BY key")
      }
    end
  end

  action :cancel do |ctx, request_id|
    ctx.sql.transaction do |tx|
      tx.execute("UPDATE agent_runs SET status = 'cancelled' WHERE id = ? AND status IN ('queued', 'running', 'retry')", request_id)
      if tx.query("SELECT status FROM agent_runs WHERE id = ?", request_id).first&.fetch("status") == "cancelled"
        pending_calls(tx, request_id).each do |turn, call|
          append_result(tx, request_id, turn, call, {"error" => "Run cancelled; an in-flight tool may already have had effects."})
        end
        tx.execute("UPDATE agent_tools SET status = 'cancelled' WHERE run_id = ? AND status = 'started'", request_id)
      end
    end
    @wake << true
    nil
  end

  action :wake do |ctx|
    if ctx.sql.query("SELECT id FROM agent_runs WHERE status IN ('queued', 'running', 'retry') LIMIT 1").empty?
      ctx.cancel_every("agent-recovery")
    end
    @wake << true
    nil
  end

  action(:sleep_now) { |ctx| ctx.sleep; nil }
  action(:destroy_agent) { |ctx| ctx.destroy; nil }

  private

  def settings
    {
      "model" => ENV.fetch("AGENT_MODEL", "gpt-4.1-mini"),
      "provider" => ENV.fetch("AGENT_PROVIDER", "openai"),
      "protocol" => ENV["AGENT_PROTOCOL"],
      "instructions" => "You are a durable assistant. Use remember/recall for notes. Only use lookup/publish when asked. Never repeat an interrupted publish: its outcome is unknown."
    }.reject { |_, value| value.nil? || value.empty? }
  end

  def drain(ctx)
    loop do
      return if ctx.aborted?
      run = ctx.sql.query("SELECT * FROM agent_runs WHERE status IN ('queued', 'running', 'retry') ORDER BY seq LIMIT 1").first
      return unless run
      delay = run.fetch("retry_at") - Time.now.to_f
      if delay > 0
        ctx.after(delay, :wake)
        return
      end
      advance(ctx, run)
    end
  end

  def advance(ctx, run)
    id = run.fetch("id")
    config = JSON.parse(run.fetch("settings"))
    ctx.sql.transaction do |tx|
      return unless active?(ctx, tx, id)
      if run.fetch("status") == "queued"
        if tx.query("SELECT seq FROM agent_messages LIMIT 1").empty?
          append_message(tx, id, RubyLLM::Message.new(role: :system, content: config.fetch("instructions")))
        end
        append_message(tx, id, RubyLLM::Message.new(role: :user, content: run.fetch("prompt")))
      end
      tx.execute("UPDATE agent_runs SET status = 'running', retry_at = 0 WHERE id = ?", id)
    end

    pending = pending_calls(ctx.sql, id)
    if pending.any?
      pending.each do |turn, call|
        return unless active?(ctx, ctx.sql, id)
        execute_tool(ctx, id, turn, call)
      end
      return
    end

    last = ctx.sql.query("SELECT payload FROM agent_messages WHERE run_id = ? ORDER BY seq DESC LIMIT 1", id).first
    message = load_message(last.fetch("payload"))
    if message.role == :assistant && !message.tool_call?
      ctx.sql.execute("UPDATE agent_runs SET status = 'completed', error = NULL WHERE id = ? AND status = 'running'", id)
      return
    end

    chat = build_chat(config)
    ctx.sql.query("SELECT payload FROM agent_messages ORDER BY seq").each { |row| chat.add_message(load_message(row.fetch("payload"))) }
    chat.with_tools(*DurableAgentExample::TOOLS.values.map { |tool| tool.new(sql: nil, idempotency_key: nil) })
    response = chat.generate
    seq = nil
    ctx.sql.transaction do |tx|
      return unless active?(ctx, tx, id)
      seq = append_message(tx, id, response)
    end
    ctx.broadcast("agent.message", {"seq" => seq, "run_id" => id, "message" => response.to_h}) unless ctx.aborted?
  rescue RubyLLM::Error, Faraday::Error => error
    return if ctx.aborted?
    attempts = run.fetch("attempts") + 1
    retry_at = Time.now.to_f + [2**[attempts, 6].min, 60].min
    ctx.sql.execute("UPDATE agent_runs SET status = ?, attempts = ?, retry_at = ?, error = ? WHERE id = ? AND status = 'running'",
      attempts < 5 ? "retry" : "failed", attempts, retry_at, error.message, id
    )
  end

  def build_chat(settings)
    context = RubyLLM.context do |config|
      config.openai_api_key = ENV["OPENAI_API_KEY"]
      config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
      config.openai_api_base = ENV["AGENT_API_BASE"] unless ENV["AGENT_API_BASE"].to_s.empty?
      config.request_timeout = 30
      config.max_retries = 0
    end
    context.chat(
      model: settings.fetch("model"),
      provider: settings.fetch("provider").to_sym,
      protocol: settings["protocol"]&.to_sym,
      assume_model_exists: true
    )
  end

  def pending_calls(sql, id)
    row = sql.query("SELECT seq, payload FROM agent_messages WHERE run_id = ? AND turn IS NULL ORDER BY seq DESC LIMIT 1", id).first
    return [] unless row
    response = load_message(row.fetch("payload"))
    return [] unless response.tool_call?
    answered = sql.query("SELECT tool_call_id FROM agent_messages WHERE turn = ?", row.fetch("seq")).map { |result| result.fetch("tool_call_id") }
    response.tool_calls.values.reject { |call| answered.include?(call.id) }.map { |call| [row.fetch("seq"), call] }
  end

  def execute_tool(ctx, id, turn, call)
    tool = DurableAgentExample::TOOLS[call.name]
    unless tool
      ctx.sql.transaction { |tx| append_result(tx, id, turn, call, {"error" => "Unknown tool"}) }
      return
    end
    intent = nil
    interrupted = false
    replay = tool::REPLAY
    ctx.sql.transaction do |tx|
      return unless active?(ctx, tx, id)
      intent = tx.query("SELECT * FROM agent_tools WHERE turn = ? AND call_id = ?", turn, call.id).first
      if intent && intent.fetch("replay") == "never"
        append_result(tx, id, turn, call, {"error" => "Tool interrupted; outcome unknown. It may already have happened. Do not repeat it."})
        tx.execute("UPDATE agent_tools SET status = 'interrupted' WHERE turn = ? AND call_id = ?", turn, call.id)
        interrupted = true
      else
        tx.execute("INSERT OR IGNORE INTO agent_tools VALUES (?, ?, ?, ?, ?, ?, 'started')",
          id, turn, call.id, call.name, replay, "#{ctx.id}:#{id}:#{turn}:#{call.id}"
        )
      end
    end
    return if interrupted
    replay = intent.fetch("replay") if intent
    key = intent ? intent.fetch("idempotency_key") : "#{ctx.id}:#{id}:#{turn}:#{call.id}"
    if replay == "local"
      ctx.sql.transaction do |tx|
        return unless active?(ctx, tx, id)
        result = tool.new(sql: tx, idempotency_key: key).call(**call.arguments, tool_call: call)
        append_result(tx, id, turn, call, result)
        tx.execute("UPDATE agent_tools SET status = 'completed' WHERE turn = ? AND call_id = ?", turn, call.id)
      end
    else
      begin
        result = tool.new(sql: nil, idempotency_key: key).call(**call.arguments, tool_call: call)
      rescue StandardError => error
        result = {"error" => "#{error.class}: #{error.message}; external outcome may be unknown"}
      end
      ctx.sql.transaction do |tx|
        return unless active?(ctx, tx, id)
        append_result(tx, id, turn, call, result)
        tx.execute("UPDATE agent_tools SET status = 'completed' WHERE turn = ? AND call_id = ?", turn, call.id)
      end
    end
  end

  def active?(ctx, sql, id)
    !ctx.aborted? && %w[queued running retry].include?(sql.query("SELECT status FROM agent_runs WHERE id = ?", id).first&.fetch("status"))
  end

  def append_result(sql, id, turn, call, result)
    message = RubyLLM::Message.new(role: :tool, tool_call_id: call.id,
      content: result.is_a?(String) ? result : JSON.generate(result)
    )
    append_message(sql, id, message, turn: turn)
  end

  def append_message(sql, id, message, turn: nil)
    payload = message.to_h.merge(content: message.content, cost: message.cost.to_h)
    sql.execute("INSERT OR IGNORE INTO agent_messages (run_id, turn, tool_call_id, payload) VALUES (?, ?, ?, ?)",
      id, turn, message.tool_call_id, JSON.generate(payload)
    ).fetch("last_insert_row_id")
  end

  def load_message(json)
    RubyLLM::Message.new(JSON.parse(json).transform_keys(&:to_sym))
  end
end
