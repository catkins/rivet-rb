require_relative "../../examples/durable_agent/agent"

if ENV["AGENT_TEST_LOCAL_BARRIER"]
  DurableAgentExample::Remember.prepend(Module.new do
    def execute(**arguments)
      result = super
      @sql.execute("INSERT INTO agent_notes (key, value) VALUES (?, ?)", "uncommitted-checkpoint", "must roll back")
      Net::HTTP.get(URI("#{ENV.fetch('AGENT_TOOL_ENDPOINT')}/local_checkpoint"))
      result
    end
  end)
end

load File.expand_path("../../examples/durable_agent/server.rb", __dir__)
