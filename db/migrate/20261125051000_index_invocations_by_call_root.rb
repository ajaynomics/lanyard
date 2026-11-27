class IndexInvocationsByCallRoot < ActiveRecord::Migration[8.2]
  def change
    add_index :invocations, "conversation_id, substr(call_id, 1, instr(call_id || '/', '/') - 1)",
      name: "index_invocations_on_conversation_id_and_call_root"
  end
end
