# Reads one of the agent's skills. Not in Tool::Catalog: nobody picks it as a
# tool. Agent#tools adds it when the agent has skills, so the instructions'
# listing always has a way to the bodies, through the ledger like any call.
class Tool::ReadSkill < Tool
  description "Read one of your skills, by the name in <available_skills>. Do this before a task that matches its description, then follow it."
  argument :name, :string, pattern: "^[a-z0-9]+(-[a-z0-9]+)*$", max_length: 64

  def call(name:)
    skill = agent.skills.find_by(name: name) or raise Refusal, "There is no skill called #{name}. The skills are: #{agent.skills.map(&:name).to_sentence}."
    { name: skill.name, content: skill.body }
  end
end
