# The agent list's search, sort and filter: one row per agent, its thread. Each scope answers one
# question and treats input it does not know as its default, so a hand-edited
# address shows a list rather than an error.
module Conversation::Listable
  extend ActiveSupport::Concern

  PER_PAGE = 30
  SORTS = {
    "recent" => { last_message_at: :desc, id: :desc },
    "created" => { created_at: :desc, id: :desc },
    "title" => Arel.sql("agents.name COLLATE NOCASE, conversations.id DESC")
  }.freeze

  included do
    # LIKE rather than full-text search: one person's history scans in
    # milliseconds, and a second copy of every message would have to be kept
    # in step by callbacks that delete_all and resync! skip. Tool output is
    # left out: it is the computer's words, not the conversation's.
    scope :search, ->(query) {
      if query.present?
        pattern = "%#{sanitize_sql_like(query.to_s.strip)}%"
        where(<<~SQL.squish, pattern: pattern)
          EXISTS (SELECT 1 FROM agents WHERE agents.id = conversations.agent_id AND agents.name LIKE :pattern ESCAPE '\\')
          OR EXISTS (SELECT 1 FROM messages WHERE messages.conversation_id = conversations.id
            AND messages.role IN ('user', 'assistant') AND messages.content LIKE :pattern ESCAPE '\\')
        SQL
      end
    }

    # Each row's newest words, a person's or a reply's, for the list to show
    # under its name (conversations/_conversation) without a query per row.
    scope :with_preview, -> {
      select(arel_table[Arel.star], <<~SQL.squish)
        (SELECT messages.content FROM messages WHERE messages.conversation_id = conversations.id
          AND messages.role IN ('user', 'assistant') AND trim(messages.content) <> ''
          ORDER BY messages.entry_id DESC LIMIT 1) AS preview
      SQL
    }

    # The agents' own threads, not their branches.
    scope :threads, -> { where(parent_id: nil) }

    scope :sorted_by, ->(key) { key.to_s == "title" ? joins(:agent).order(SORTS["title"]) : order(SORTS.fetch(key.to_s, SORTS["recent"])) }

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
