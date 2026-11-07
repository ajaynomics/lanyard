# An agent is one thread now (CONTEXT.md): its own context, name, instructions,
# model, computer and notes. Each conversation that began a family (no parent)
# becomes an agent of its own, a copy of the agent it ran under, named after it
# and carrying its branches; archived stays archived. The agent itself keeps its
# most recent unarchived thread, or none, and then starts a fresh one the first
# time it is opened (durable_id waits until then).
#
# A moved thread keeps its sidecar conversation, which the sidecar still files
# under the old agent: it reads from this database's copy, and continuing it
# is refused rather than run as the wrong agent. Only archived threads moved on
# the first install, whose computers were already deleted. Not reversible.
class OneThreadPerAgent < ActiveRecord::Migration[8.2]
  COPIED = %w[ user_id instructions model thinking_level time_zone tool_names capabilities ].freeze

  def up
    change_column_null :conversations, :durable_id, true

    select_rows("SELECT id FROM agents").flatten.each do |agent_id|
      tops = select_all("SELECT id, title, archived_at FROM conversations WHERE agent_id = #{agent_id} AND parent_id IS NULL ORDER BY last_message_at DESC, id DESC").to_a
      kept = tops.find { it["archived_at"].nil? }
      (tops - [ kept ]).each { move(agent_id, it) }
      start(agent_id) unless kept
    end

    remove_index :conversations, :agent_id
    add_index :conversations, :agent_id, unique: true, where: "parent_id IS NULL", name: "index_conversations_one_thread_per_agent"
    add_index :conversations, :agent_id
  end

  def down = raise ActiveRecord::IrreversibleMigration

  private
    def move(agent_id, top)
      agent = select_one("SELECT * FROM agents WHERE id = #{agent_id}")
      name = top["title"].presence || agent["name"]
      copy = insert_returning("agents", agent.slice(*COPIED).merge("name" => name))
      %w[ skills prompts notes ].each do |table|
        kept = connection.columns(table).map(&:name) - %w[ id agent_id ]
        execute "INSERT INTO #{table} (agent_id, #{kept.join(", ")}) SELECT #{copy}, #{kept.join(", ")} FROM #{table} WHERE agent_id = #{agent_id}"
      end
      if (computer = select_one("SELECT * FROM computers WHERE agent_id = #{agent_id}"))
        insert_returning("computers", computer.except("id").merge("agent_id" => copy, "name" => computer["name"].sub(/-b\d+\z/, "-b#{copy}")))
      end
      execute "UPDATE conversations SET agent_id = #{copy} WHERE id = #{top["id"]} OR root_id = #{top["id"]}"
    end

    # The thread an agent opens first; the sidecar admits it then (Conversation#admit!).
    def start(agent_id)
      user_id = select_value("SELECT user_id FROM agents WHERE id = #{agent_id}")
      insert_returning("conversations", "agent_id" => agent_id, "user_id" => user_id, "request_id" => "thread", "last_message_at" => Time.current)
    end

    def insert_returning(table, row)
      row = row.merge("created_at" => row["created_at"] || Time.current, "updated_at" => Time.current)
      execute "INSERT INTO #{table} (#{row.keys.join(", ")}) VALUES (#{row.values.map { connection.quote(it) }.join(", ")})"
      select_value("SELECT last_insert_rowid()")
    end
end
