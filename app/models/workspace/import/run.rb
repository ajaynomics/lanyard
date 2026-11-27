# One import as it goes: the copy, its keys, the workspace it comes into, and
# for each table the id here of every row that came, so a reference to it
# follows. A reference to a row not yet come (an agent's mail to another, a
# branch's thread) is filled in once everything has.
class Workspace::Import::Run
  attr_reader :source, :keys, :workspace, :entries, :blobs
  # The copy's id of the person who owns the import.
  attr_accessor :owner

  def initialize(source, keys)
    @source, @keys = source, keys
    @entries = Workspace::Import::Entries.new(source)
    @ids = {}
    @left = Hash.new { |left, table| left[table] = Hash.new(0) }
    @deferred = []
    @blobs = []
    @matched = []
  end

  def into(workspace) = @workspace = workspace

  # A table's ids so far, from its first row on: it has begun to come.
  def ids(table) = @ids[table] ||= {}
  def id(table, source_id) = @ids.dig(table, source_id)
  def came?(table) = @ids.key?(table)

  # A person of the copy who is already here, by email, and keeps their own settings.
  def matched(source_id, person)
    ids("users")[source_id] = person.id
    @matched << person.email
  end

  def defer(table, id, column, to:, source_id:) = @deferred << [ table, id, column, to, source_id ]

  def link_deferred
    @deferred.each do |table, id, column, to, source_id|
      next unless (linked = id(to, source_id))
      ApplicationRecord.connection.update("UPDATE #{table} SET #{column} = #{Integer(linked)} WHERE id = #{Integer(id)}")
    end
  end

  def verify_reporting_tree!
    agents = workspace.agents.where(id: ids("agents").values).to_a
    tree = Workspace::ReportingTree.new(agents)
    agents.each do |agent|
      if (problem = tree.problem(agent, agent.parent_id))
        raise Workspace::Import::Refused, "Invalid reporting line for #{agent}: #{problem}"
      end
    end
  end

  # What stays in the copy, and why.
  def leave(table, reason, count = 1) = @left[table][reason] += count
  def left(table) = @left[table]

  # Files this run put in storage, removed again when it comes to nothing:
  # their rows went with the rollback, the files would not.
  def discard_files = @blobs.each { it.service.delete(it.key) }

  def report(check)
    { "source_version" => source.version,
      "owner" => workspace.owner&.email,
      "already_here" => @matched,
      "tables" => check.map(&:to_h),
      "left" => @left.reject { |_, reasons| reasons.empty? }.transform_values(&:to_h),
      "stays" => Workspace::Import::Refusal::STAYS.excluding("schema_migrations", "ar_internal_metadata").index_with { source.count(it) }.select { |_, count| count.positive? },
      "not_carried" => Workspace::Import::Table.not_carried(source),
      "references" => Workspace::Import::References.new(self).all,
      "reconnect" => Workspace::Import::Reconnect.all(self),
      "threads" => Workspace::Import::Threads.plan(self),
      "store" => source.store.present?,
      "host_steps" => Workspace::Import::Threads.host_steps(self) }
  end
end
