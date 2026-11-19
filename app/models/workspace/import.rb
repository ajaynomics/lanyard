# Another install of this app moved in as a shared workspace (docs/import.md):
# from a copy of its storage folder, its people, agents, threads and files
# come here with new ids, every reference following, and its secrets
# re-encrypted under this install's keys. Its sidecar's threads follow into
# this install's sidecar (Threads). The copy is only read. Nothing is written
# unless all of it can be, the same copy never comes twice, and the import is
# kept as the record of what came.
class Workspace::Import < ApplicationRecord
  # Why the copy cannot come in, said before anything is written.
  class Refused < StandardError; end

  belongs_to :workspace

  # The diff of the copy against what came, table by table (Check), for the run that made it.
  attr_accessor :check

  # Brings the copy in, into the shared workspace `into` or else a new one
  # named `name`, owned by the person whose email is `owner` there (the
  # copy's first person if none is given), who already signs in here, with
  # each of its people a member. `rehearse` runs it all, prints the same
  # report, and leaves nothing behind; its threads are not carried.
  def self.run!(source:, keys:, owner: nil, name: nil, into: nil, rehearse: false)
    source = Source.new(source)
    Refusal.new(source, keys, owner:, into:).verify!
    run = Run.new(source, keys)
    import = nil
    transaction do
      run.into into || Workspace.create!(name: name.presence || "Imported install")
      People.new(run).bring(owner:)
      Table.all.each { it.copy(run) }
      run.link_deferred
      Files.new(run).copy
      check = Check.new(run).results
      raise Refused, "The copy and what came differ:\n#{check.reject(&:matches?).join("\n")}" unless check.all?(&:matches?)
      import = create!(workspace: run.workspace, source_digest: source.digest, source_version: source.version, report: run.report(check))
      import.check = check
      raise ActiveRecord::Rollback if rehearse
    end
    run.discard_files if rehearse
    committed = !rehearse
    import.carry!(source) if committed
    import
  rescue
    # Once committed, the files are the import's: a thread not carried is carried again later.
    run&.discard_files unless committed
    raise
  ensure
    source&.close
  end

  # Carries each thread not yet carried into this install's sidecar, and its
  # computer's files (Threads). Run again, it carries only what is left.
  def carry!(source)
    update!(report: Threads.new(self, source).carry)
  end

  # Each carried computer file whose hash here is not the one it had there.
  def verify_files = Threads.differing(self)

  # The report as the task prints it: the diff, table by table, then what stayed and why.
  def summary
    [ "Copy at release #{report["source_version"]} into workspace #{workspace_id} (#{workspace.name}), owned by #{report["owner"]}",
      *check&.map(&:to_s),
      *(check && [ check.all?(&:matches?) ? "Every table matches." : "Tables differ." ]),
      *report["already_here"].map { "Already here, by sign-in: #{it}, who keeps their own settings here" },
      *report["left"].flat_map { |table, reasons| reasons.map { |reason, count| "Stayed: #{count} #{table}, #{reason}" } },
      *report["stays"].map { |table, count| "Stayed: #{count} #{table}, kept by the other install for itself" },
      *report["not_carried"].map { "Not carried: #{it}" },
      *report.fetch("reconnect", []).map { "Reconnect: #{it["name"]}#{" (a thread's)" if it["thread"]}, #{it["how"]}, on the workspace's Connectors page" },
      *threads,
      *report.fetch("host_steps", []).map { "On its host: #{it}" },
      *report.fetch("references", []).map { "Refers to: #{it["table"]} #{it["id"]} #{it["column"]}, #{it["kind"]} #{it["value"]}" } ].join("\n")
  end

  private
    def threads
      threads, carried, waiting = report.fetch("threads", {}).size, report.fetch("carried", {}).size, report.fetch("waiting", []).size
      if threads.zero? then []
      elsif !report["store"] then [ "Threads: #{threads} start afresh: the copy holds no sidecar store (agent-durable.sqlite), so the model sees only their new messages" ]
      elsif waiting.positive? then [ *("Threads: #{carried} carried from the other sidecar" if carried.positive?),
        "Threads: #{waiting} not carried yet: run bin/rails workspaces:carry with the same SOURCE once this install's sidecar is up" ]
      elsif carried.zero? then [ "Threads: #{threads} to carry from the other sidecar once imported" ]
      else [ "Threads: #{carried} carried from the other sidecar", *(threads > carried ? [ "Threads: #{threads - carried} started afresh before they were carried" ] : []) ]
      end
    end
end
