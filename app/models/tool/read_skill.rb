# Reads one of the agent's skills. Not in Tool::Catalog: nobody picks it as a
# tool. Agent#tools adds it when the agent has a ready skill, so the
# instructions' listing always has a way to the bodies, through the ledger
# like any call. A skill's folder goes to the agent's computer as a file a
# tool found does (Invocation#file?, agent/files.mjs), at the same place each
# time (Skill::OnComputer).
class Tool::ReadSkill < Tool
  description "Read one of your skills, by the name in <available_skills>. Do this before a task that matches its description, then follow it. " \
    "A skill with files puts them on your computer and says where; open them only when the skill says to."
  argument :name, :string, pattern: "^[a-z0-9]+(-[a-z0-9]+)*$", max_length: 64

  def self.saves_file? = true

  # The skill and its files are read in one transaction, so the answer is one
  # approved version; the file it names is that version, by its digest.
  def call(name:)
    skill = Skill.transaction { agent.skills.ready.includes(:files).find_by(name: name) } or
      raise Refusal, "There is no skill called #{name}. The skills are: #{agent.skills.ready.map(&:name).to_sentence}."
    answer = { name: skill.name, content: skill.body }
    return answer unless skill.folder?
    if skill.on_computer?(agent.computer)
      answer.merge(location: "#{skill.location}/#{Skill::Folder::MARKDOWN}", folder: skill.location, files: skill.files.map(&:path),
        file: { name: "#{skill.name}.tar", type: "application/x-tar", size: skill.files.sum(&:size), digest: skill.contents_digest })
    else
      answer.merge(files: skill.files.map(&:path), note: "This skill has other files, but you have no computer to put them on, so you have its SKILL.md alone.")
    end
  end

  # The folder, for the sidecar to unpack: the version the call answered with,
  # still ready, read whole in one transaction; nothing once it has changed or
  # is no longer ready.
  def download(name:, file:)
    Skill.transaction do
      skill = agent.skills.ready.includes(:files).find_by(name: name)
      skill.tarball if skill && skill.contents_digest == file["digest"]
    end
  end
end
