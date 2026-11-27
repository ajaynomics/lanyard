# The agent list's search, sort and filter: one row per agent, its thread. Each scope answers one
# question and treats input it does not know as its default, so a hand-edited
# address shows a list rather than an error.
module Conversation::Listable
  extend ActiveSupport::Concern

  PER_PAGE = 30
  # "recent" puts what needs the person first, then the newest (Conversation::Standing).
  SORTS = {
    "created" => { created_at: :desc, id: :desc },
    "title" => Arel.sql("agents.name COLLATE NOCASE, conversations.id DESC")
  }.freeze

  included do
    # Agent names only: a message's words are searched one agent at a time,
    # in Ruby (Agent::MessageSearch).
    scope :search, ->(query) {
      if query.present?
        pattern = "%#{sanitize_sql_like(query.to_s.strip)}%"
        where("EXISTS (SELECT 1 FROM agents WHERE agents.id = conversations.agent_id AND agents.name LIKE ? ESCAPE '\\')", pattern)
      end
    }

    # A reply can have words between calls. Skip only replies made entirely of
    # the markers written by entryView, without loading a thread per list row.
    scope :with_preview, -> {
      select(arel_table[Arel.star], <<~SQL.squish)
        (SELECT messages.content FROM messages WHERE messages.conversation_id = conversations.id
          AND messages.role IN ('user', 'assistant') AND trim(messages.content, char(9, 10, 13, 32)) <> ''
          AND NOT (messages.role = 'assistant' AND json_array_length(messages.tool_calls) > 0
            AND replace(replace(replace(replace(messages.content, ' ', ''), char(9), ''), char(10), ''), char(13), '')
              IS (SELECT group_concat('[tool:' || json_extract(value, '$.name') || ']', '' ORDER BY key)
                  FROM json_each(messages.tool_calls)))
          ORDER BY messages.entry_id DESC, messages.id DESC LIMIT 1) AS preview
      SQL
    }

    # The agents' own threads, not their branches.
    scope :threads, -> { where(parent_id: nil) }

    scope :sorted_by, ->(key) {
      case key.to_s
      when "title" then joins(:agent).order(SORTS["title"])
      when "created" then order(SORTS["created"])
      else by_news
      end
    }

    scope :filtered_by, ->(key) {
      case key.to_s
      when "waiting" then active.where(status: "waiting")
      when "archived" then archived
      when "all" then all
      else active
      end
    }
  end
end
