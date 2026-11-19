# Development only: made-up records for trying the Watch companion (ios/) on
# simulators. The local developer (the "Sign in as a local developer" button)
# gets an agent on the free scripted stand-in and four calls waiting for an
# answer: two small cards to allow and decline, one a person must answer every
# time, and one too long for the Watch. Every one of their agents moves to the
# stand-in, so nothing reaches a paid model.
#
# The calls were never made by the agent's server, so an answer is recorded and
# nothing runs: no note is forgotten and no instruction changes.
#
#   bin/rails runner script/watch_fixture.rb
#
# Run it again to put the four cards back as they were.
abort "Development only." unless Rails.env.development?

STAND_IN = "local/stand-in".freeze
TASK = "watch-fixture".freeze

person = User.sign_in!(sub: "development", email: "developer@localhost", name: "Developer")
agent = person.agents.find_by(name: "Watch fixture") ||
  person.personal_workspace.agents.create!(user: person, name: "Watch fixture", instructions: "A made-up agent for trying the Watch companion. Answer briefly.",
    model: STAND_IN, thinking_level: "low", time_zone: "UTC", tool_names: %w[ forget_note remember_note list_notes ], capabilities: [])
person.agents.where.not(model: STAND_IN).find_each { it.update_columns(model: STAND_IN) }

agent.notes.remember("parking-spot", "Level 2, bay 14 (made up).")
agent.notes.remember("old-wifi", "Not a real network.")

conversation = agent.conversation
conversation.invocations.where(task_id: TASK).destroy_all

cards = {
  "allow-me" => [ "forget_note", { "key" => "parking-spot" } ],
  "decline-me" => [ "forget_note", { "key" => "old-wifi" } ],
  "every-time" => [ "change_yourself", { "instructions" => "Answer in one short sentence." } ],
  "phone-only" => [ "change_yourself", { "instructions" => "A long made-up instruction. " * 60 } ]
}

cards.each do |call_id, (tool, arguments)|
  conversation.invocations.create!(task_id: TASK, call_id: call_id, tool_name: tool, arguments: arguments, state: :awaiting_person,
    expires_at: Invocation::WAIT.from_now,
    digest: Invocation.digest_for(conversation, task_id: TASK, call_id: call_id, tool: tool, arguments: arguments))
end

waiting = person.invocations.waiting_for_approval
puts "Fixture person: developer@localhost (sign in with \"Sign in as a local developer\")"
puts "Agent: #{agent} (conversation #{conversation.id}, model #{agent.reload.model})"
waiting.each { |it| card = Invocation::Card.new(it); puts "Card #{card.id}: #{card.as_json[:title]}#{' (phone only)' unless card.small?}" }
