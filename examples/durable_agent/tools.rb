require "ruby_llm"
require "net/http"

# Tools for the durable-agent example, not part of the gem's public API.
# @api private
module DurableAgentExample
  class Tool < RubyLLM::Tool
    def initialize(sql:, idempotency_key:)
      @sql = sql
      @idempotency_key = idempotency_key
    end

    private

    def request(path, data, method: :get)
      uri = URI("#{ENV.fetch('AGENT_TOOL_ENDPOINT')}/#{path}")
      uri.query = URI.encode_www_form(data) if method == :get
      request = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
      if method == :post
        request["Content-Type"] = "application/json"
        request["Idempotency-Key"] = @idempotency_key
        request.body = JSON.generate(data)
      end
      response = Net::HTTP.start(uri.host, uri.port,
        use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 30
      ) { |http| http.request(request) }
      raise "tool endpoint returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    end
  end

  class Remember < Tool
    REPLAY = "local"
    def self.tool_name = "remember"
    description "Remember a text note under a key. Stored durably with this tool's result."
    parameter :key, type: :string
    parameter :value, type: :string

    def execute(key:, value:)
      @sql.execute("INSERT INTO agent_notes (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value)
      {"stored" => key}
    end
  end

  class Recall < Tool
    REPLAY = "local"
    def self.tool_name = "recall"
    description "Read a previously remembered note."
    parameter :key, type: :string

    def execute(key:)
      {"value" => @sql.query("SELECT value FROM agent_notes WHERE key = ?", key).first&.fetch("value")}
    end
  end

  class Lookup < Tool
    REPLAY = "safe"
    def self.tool_name = "lookup"
    description "Look up a topic through the configured read-only HTTP service."
    parameter :topic, type: :string

    def execute(topic:)
      request("lookup", {topic: topic})
    end
  end

  class Publish < Tool
    REPLAY = "never"
    def self.tool_name = "publish"
    description "Publish a note through the configured HTTP service. Do not repeat a call whose outcome is unknown."
    parameter :text, type: :string

    def execute(text:)
      request("publish", {text: text}, method: :post)
    end
  end

  TOOLS = [Remember, Recall, Lookup, Publish].to_h { |tool| [tool.tool_name, tool] }.freeze
end
