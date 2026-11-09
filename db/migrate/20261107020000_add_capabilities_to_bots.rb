class AddCapabilitiesToBots < ActiveRecord::Migration[8.2]
  # Every bot had code mode before capabilities could be switched; existing
  # bots get all three, as a new bot does.
  ALL = %w[ codemode subagents web_search ].freeze

  def change
    add_column :bots, :capabilities, :json, default: ALL, null: false
    add_column :bot_revisions, :capabilities, :json, default: [], null: false
  end
end
