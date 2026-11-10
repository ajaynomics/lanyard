# Says in the log which agents want more tools than they can be given
# (Agent#over_tool_limit?): a deploy can add tools to a connector, and the
# last connectors' tools are then looked up instead of declared. Not while
# assets build (no database then) or in tests, which call it themselves.
Rails.application.config.after_initialize do
  next if ENV["SECRET_KEY_BASE_DUMMY"] || Rails.env.test?

  Agent.warn_over_tool_limit
end
