class AddReachToAgentVoiceCalls < ActiveRecord::Migration[8.2]
  def change
    # Agent::VoiceCall::Reach: a call is a stranger's unless it came from the owner's number.
    add_column :agent_voice_calls, :reach, :string, null: false, default: "stranger"
  end
end
