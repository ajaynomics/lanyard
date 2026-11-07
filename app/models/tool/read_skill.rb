# Reads one of the bot's skills. Not in Tool::Catalog: nobody picks it as a
# tool. Bot#tools adds it when the bot has skills, so the instructions'
# listing always has a way to the bodies, through the ledger like any call.
class Tool::ReadSkill < Tool
  description "Read one of your skills, by the name in <available_skills>. Do this before a task that matches its description, then follow it."
  argument :name, :string, pattern: "^[a-z0-9]+(-[a-z0-9]+)*$", max_length: 64

  def call(name:)
    skill = bot.skills.find_by(name: name) or raise Refusal, "There is no skill called #{name}. The skills are: #{bot.skills.map(&:name).to_sentence}."
    { name: skill.name, content: skill.body }
  end
end
