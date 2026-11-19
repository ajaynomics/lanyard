require "rubygems/package"

# Where a skill's folder sits on the agent's computer: the same path every
# time, so its SKILL.md can name references and scripts the agent opens or
# runs only when it needs them. read_skill puts it there (Tool::ReadSkill,
# agent/files.mjs), as one tar the sidecar unpacks; only a Sprite takes it,
# as only a Sprite takes any file (agent/files.mjs). Elsewhere the agent
# gets the SKILL.md alone.
module Skill::OnComputer
  extend ActiveSupport::Concern

  ROOT = "/home/agent/skills"

  def folder? = files.any?

  def location = "#{ROOT}/#{name}"

  def on_computer?(computer) = folder? && computer.present? && computer.on? && computer.sprites?

  # SKILL.md written back from its parts, as the agent's folder holds it.
  def to_markdown
    front = { "name" => name, "description" => description }.to_yaml.delete_prefix("---\n")
    "---\n#{front}---\n\n#{body.strip}\n"
  end

  # The whole folder, each program marked as one.
  def tarball
    io = StringIO.new(+"".b)
    Gem::Package::TarWriter.new(io) do |tar|
      tar.add_file_simple(Skill::Folder::MARKDOWN, 0o644, to_markdown.bytesize) { it.write(to_markdown) }
      files.each { |file| tar.add_file_simple(file.path, file.executable ? 0o755 : 0o644, file.size) { it.write(file.content) } }
    end
    io.string
  end
end
