# GPT-6.2 Sol and GPT-6.2 Astra replace GPT-6.1 Sol and GPT-6 Astra on the
# ChatGPT subscription routes, which ChatGPT's own list now calls "previous
# generation" (#272). Agents on them move to the new model on the same route,
# so the same subscription still pays. The API key's openai/gpt-6.1-sol has no
# 6.2 offered yet and no other route with the same payer, so an agent on it
# stays, still runs and still saves (Agent keeps a model taken off the list),
# and is named here for its owner to choose.
class MoveAgentsToGpt62 < ActiveRecord::Migration[8.2]
  MOVES = %w[ openai-codex openai-chatgpt ].flat_map do |route|
    { "#{route}/gpt-6.1-sol" => "#{route}/gpt-6.2-sol", "#{route}/gpt-6-astra" => "#{route}/gpt-6.2-astra" }.to_a
  end.to_h.freeze
  KEPT = %w[ openai/gpt-6.1-sol ].freeze

  def up
    moved = MOVES.sum do |from, to|
      update("UPDATE agents SET model = #{connection.quote(to)} WHERE model = #{connection.quote(from)}")
    end
    say "moved #{moved} agents to GPT-6.2"
    select_rows("SELECT id, model FROM agents WHERE model IN (#{KEPT.map { connection.quote(it) }.join(", ")}) ORDER BY id").each do |id, model|
      say "agent #{id} stays on #{model}: the API key's route offers no 6.2 yet"
    end
  end

  def down
    MOVES.each { |from, to| execute("UPDATE agents SET model = #{connection.quote(from)} WHERE model = #{connection.quote(to)}") }
  end
end
