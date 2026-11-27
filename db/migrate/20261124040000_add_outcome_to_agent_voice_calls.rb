class AddOutcomeToAgentVoiceCalls < ActiveRecord::Migration[8.2]
  def up
    add_column :agent_voice_calls, :outcome, :string
    # Offers from before answering existed have long expired: never answer them.
    execute "UPDATE agent_voice_calls SET outcome = 'missed'"
  end

  def down
    remove_column :agent_voice_calls, :outcome
  end
end
