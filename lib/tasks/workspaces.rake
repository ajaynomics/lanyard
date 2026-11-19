# Brings a copy of another install in as a shared workspace (docs/import.md).
# Where the copy is and who owns it are arguments; the other install's keys
# are not, so they never reach a shell's history or a process list: a file
# (SOURCE_KEYS) or the environment (SOURCE_SECRET_KEY_BASE).
#
#   SOURCE=/path/to/copy/storage SOURCE_KEYS=/path/to/keys.yml OWNER=owner@example.com NAME="Old office" \
#     bin/rails workspaces:import
#
# WORKSPACE=<id> brings it into that shared workspace, which OWNER owns here,
# rather than a new one. REHEARSE=1 runs it all and prints the same report,
# then undoes it.
namespace :workspaces do
  desc "Bring a copy of another install in as a shared workspace (docs/import.md)"
  task import: :environment do
    abort "SOURCE= names the folder holding the copy's #{Workspace::Import::Source::DATABASE}" if ENV["SOURCE"].blank?
    keys = ENV["SOURCE_KEYS"].present? ? Workspace::Import::Keys.load(ENV["SOURCE_KEYS"]) : Workspace::Import::Keys.new(secret_key_base: ENV.delete("SOURCE_SECRET_KEY_BASE"))
    into = Workspace.find(ENV["WORKSPACE"]) if ENV["WORKSPACE"].present? # tenancy-ok: the operator names the workspace; the import checks OWNER owns it
    rehearse = ENV["REHEARSE"] == "1"
    import = Workspace::Import.run!(source: ENV["SOURCE"], keys:, owner: ENV["OWNER"], name: ENV["NAME"], into:, rehearse:)
    puts import.summary
    puts rehearse ? "Rehearsal: nothing was kept." : "Imported as workspace #{import.workspace_id}."
  rescue Workspace::Import::Refused => error
    abort error.message
  end

  # The threads an import could not carry yet, from the same copy: those
  # carried are not asked for again, so running it twice changes nothing.
  desc "Carry an import's threads not yet carried into this sidecar (docs/import.md)"
  task carry: :environment do
    abort "SOURCE= names the folder the import came from" if ENV["SOURCE"].blank?
    source = Workspace::Import::Source.new(ENV["SOURCE"])
    import = Workspace::Import.find_by(source_digest: source.digest) or abort "No import came from this copy" # tenancy-ok: the import this copy made
    import.carry!(source)
    puts import.summary
    differing = import.verify_files
    abort "Computer files differ from the copy:\n#{differing.join("\n")}" if differing.any?
  ensure
    source&.close
  end
end
