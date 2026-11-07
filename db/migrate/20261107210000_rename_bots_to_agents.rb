# The assistant is an agent, not a bot (docs/design/PLAN.md, "What things are"):
# the tables, columns and indexes take the model's new name. Nothing moves and
# no row changes, so a rollback just renames them back.
#
# SQLite rewrites the foreign keys that point at a renamed table by itself, and
# Rails renames the indexes that carry the default names. mcp_servers.bot_id is
# no longer read (McpServer ignores it) but is renamed with the rest, so the
# later migration that drops it finds one name everywhere.
#
# Unlike AGENTS.md's rule, this is not safe across a rolling deploy: until the
# old release is replaced it fails on any query that names bots ("no such
# table"). Accepted on staging; deploy when no run is in progress. No queued
# job carries an Agent (jobs take a Conversation, Invocation, McpServer or
# ConcourseAgent), so nothing queued needs draining.
class RenameBotsToAgents < ActiveRecord::Migration[8.2]
  OWNED = %i[ agent_revisions computers concourse_agents conversations mcp_servers notes prompts skills ].freeze

  def change
    rename_table :bots, :agents
    rename_table :bot_revisions, :agent_revisions
    OWNED.each { rename_column it, :bot_id, :agent_id }
  end
end
