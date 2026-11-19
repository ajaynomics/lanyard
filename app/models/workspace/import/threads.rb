# The other install's threads, carried into this install's sidecar once their
# rows have come (docs/import.md). The sidecar is asked for each thread as it
# is for any new one, under its id here, with the copy of the other sidecar's
# store and the thread's id there: it starts the thread with what its model
# saw (agent/carry.mjs). Asked after the rows are committed, as the sidecar
# checks each against them; asked again, it finds the same thread, and one
# already carried is not asked for.
#
# A local computer's folder for the thread comes with it, under the thread's
# new id, each file's SHA-256 recorded before and checked after. A Sprite's or
# an SSH host's files stay where they are: copying them is a step on that
# host, and the report says which.
class Workspace::Import::Threads
  # Each thread that came and the other sidecar ran: its id there, and its agent's.
  def self.plan(run)
    plan = {}
    run.source.each("conversations") do |row|
      id = run.id("conversations", row["id"])
      plan[id.to_s] = [ row["durable_id"].to_s, row["agent_id"] ] if id && row["durable_id"].present?
    end
    plan
  end

  # The computers whose files are not this install's to copy.
  def self.host_steps(run)
    steps = []
    run.source.each("computers") do |row|
      name = run.source.find("agents", row["agent_id"])&.dig("name")
      case row["provider"]
      when "sprites"
        sprites = []
        run.source.each("conversations") { sprites << "#{row["name"]}-c#{it["durable_id"]}" if it["agent_id"] == row["agent_id"] && it["durable_id"].present? }
        steps << "#{name}'s computer is a Sprite: its files stay on the other install's Sprites (#{sprites.join(", ")}); copy what is needed into the new ones by hand"
      when "ssh" then steps << "#{name}'s computer is an SSH host (#{row["ssh_host"]}): its files stay there; give its new key (agent-<id>) access"
      end
    end
    steps
  end

  def initialize(import, source)
    @import, @source = import, source
  end

  # Returns the report as it now stands.
  def carry
    report = @import.report.deep_dup
    report["carried"] ||= {}
    report["computer_files"] ||= {}
    report["waiting"] = []
    store = @source.store
    report.fetch("threads", {}).each do |id, (from, agent_id)|
      next if report["carried"].key?(id)
      conversation = @import.workspace.conversations.find_by(id:)
      next unless conversation && store && conversation.durable_id.nil?
      conversation.carry!(store:, from:)
      report["carried"][id] = conversation.durable_id
      folder = @source.computer_folder(agent_id, from)
      report["computer_files"][id] = copy(folder, Pathname(conversation.agent.workdir).join(conversation.durable_id)) if folder
    rescue DurableAssistants::PiDurable::Client::Error
      report["waiting"] << id
    end
    report
  end

  # Each copied file whose hash here is not the one it had there.
  def self.differing(import)
    import.report.fetch("computer_files", {}).flat_map do |id, files|
      conversation = import.workspace.conversations.find_by(id:)
      folder = conversation&.durable_id && Pathname(conversation.agent.workdir).join(conversation.durable_id)
      files.reject { |path, sha256, _| folder && folder.join(path).file? && Digest::SHA256.file(folder.join(path)).hexdigest == sha256 }.map { "#{id}: #{it.first}" }
    end
  end

  private
    # Regular files only: a link there points into the other host.
    def copy(from, to)
      files = from.glob("**/*", File::FNM_DOTMATCH).select { it.file? && !it.symlink? }.sort.map do |file|
        path = file.relative_path_from(from).to_s
        sha256 = Digest::SHA256.file(file).hexdigest
        target = to.join(path)
        raise Workspace::Import::Refused, "#{target} is already there" if target.exist? && Digest::SHA256.file(target).hexdigest != sha256
        FileUtils.mkdir_p(target.dirname)
        FileUtils.cp(file, target, preserve: true)
        raise Workspace::Import::Refused, "#{target} is not the file it was copied from" unless Digest::SHA256.file(target).hexdigest == sha256
        [ path, sha256, file.size ]
      end
      files
    end
end
