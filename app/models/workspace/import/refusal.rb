# Everything that stops the copy coming in, found before anything is
# written and said all at once, so a rehearsal shows what to settle first.
class Workspace::Import::Refusal
  # Unique here across the install: a copy whose rows hold one already here
  # was imported before, or is the same identity set up twice.
  TAKEN = {
    "agents" => %w[ email_name phone_number ],
    "campfire_bots" => %w[ token ],
    "concourse_agents" => %w[ client_id ],
    "workflow_steps" => %w[ call_id ]
  }.freeze

  # What stays in the copy, table by table: what only meant something to
  # that install, its people's devices, or what its sidecar or Active
  # Storage keeps for itself. Said in docs/import.md.
  STAYS = %w[
    schema_migrations ar_internal_metadata action_mailbox_inbound_emails active_storage_blobs active_storage_variant_records
    ahoy_visits ahoy_events push_subscriptions push_devices push_attempts watches shares campfire_rooms
    conversation_submissions screen_passes sign_in_links workspaces workspace_memberships workspace_invitations workspace_imports
  ].freeze

  def initialize(source, keys, owner:, into: nil)
    @source, @keys, @owner, @into = source, keys, owner, into
  end

  def verify!
    reasons = [ *copy, *(@source.exists? ? [ *imported, *release, *owner, *into, *connector_names, *taken, *people, *secrets, *files, *threads ] : []) ]
    raise Workspace::Import::Refused, "The copy cannot come in:\n#{reasons.map { "- #{it}" }.join("\n")}" if reasons.any?
  end

  private
    def copy
      if !@source.exists? then [ "#{@source.database} is not there" ]
      elsif @source.unfinished? then [ "#{@source.database}-wal holds writes not yet in the database: make the copy with SQLite's .backup, from a stopped install" ]
      else []
      end
    end

    def imported
      import = Workspace::Import.find_by(source_digest: @source.digest) # tenancy-ok: whether this copy came before, into any workspace
      import ? [ "this copy was already imported, as workspace #{import.workspace_id}, on #{import.created_at.to_date}" ] : []
    end

    def release
      here = ApplicationRecord.connection_pool.migration_context.current_version
      unknown = @source.tables - STAYS - Workspace::Import::Table.all.map(&:name) - %w[ users active_storage_attachments ]
      [ ("the copy is from a newer release (#{@source.version}) than this one (#{here}): upgrade this install first" if @source.version.to_i > here),
        *unknown.select { @source.count(it).positive? }.map { "the copy's table #{it} is unknown at this release" } ].compact
    end

    # The person who owns the import already signs in here: they are who
    # answers for it, and so who owns the workspace it comes into.
    def owner
      row = Workspace::Import::People.owner(@source, @owner)
      if !row then [ "nobody in the copy has the email #{@owner}" ]
      elsif !Workspace::Import::People.here(row) then [ "#{row["email"]} owns the import but does not sign in here: they sign in here once first" ]
      else []
      end
    end

    def into
      return [] unless @into
      return [ "#{@into.name.presence || "That"} is a personal workspace: import into a shared one, or a new one" ] if @into.personal?
      row = Workspace::Import::People.owner(@source, @owner)
      person = row && Workspace::Import::People.here(row)
      return [ "#{row&.dig("email") || @owner} does not own #{@into.name}" ] if person && @into.owner != person
      @into.import ? [ "#{@into.name} already holds another install's import: import into a new workspace" ] : []
    end

    # Of everything that comes, only connectors are named once per workspace
    # here (a unique index on workspace and name); the rest are unique per
    # agent, and an agent comes whole. The owner's from every one of the
    # copy's workspaces come into one, so two with one name cannot both come,
    # nor one whose name the workspace it comes into already has.
    def connector_names
      table, owner = Workspace::Import::Table.named("mcp_servers"), Workspace::Import::People.owner(@source, @owner)&.dig("id")
      coming = Hash.new { |names, name| names[name] = [] }
      @source.each("mcp_servers") { coming[it["name"]] << it if it["conversation_id"].nil? && table.comes?(it, owner) }
      here = @into ? @into.mcp_servers.global.pluck(:name) : []
      coming.flat_map do |name, rows|
        [ ("the connector #{name} comes from #{rows.size == 2 ? "two" : rows.size} of the copy's workspaces, #{rows.map { where(it) }.to_sentence}, " \
            "and a workspace here names its connectors once: rename or switch off one of them there first" if rows.many?),
          ("the connector #{name} is already in #{@into.name}: rename one first" if here.include?(name)) ].compact
      end
    end

    def where(connector)
      workspace = connector["workspace_id"] && @source.find("workspaces", connector["workspace_id"])
      "#{workspace&.dig("name").presence || "workspace #{connector["workspace_id"]}"} (#{connector["url"] || connector["command"]})"
    end

    def taken
      TAKEN.flat_map do |table, columns|
        model = Workspace::Import::Table.named(table).model
        columns.filter_map do |column|
          values = @source.values(table, column)
          taken = values.each_slice(500).flat_map { model.where(column => it).pluck(column) } # tenancy-ok: a value unique across the install
          "#{table}.#{column} already here: #{taken.join(", ")}#{already_imported(model, column, taken)}" if taken.any?
        end
      end
    end

    def already_imported(model, column, taken)
      return "" unless model == Agent
      imports = Workspace::Import.where(workspace_id: Agent.where(column => taken).select(:workspace_id)) # tenancy-ok: which import brought these agents
      imports.any? ? " (already imported, as workspace #{imports.map(&:workspace_id).join(", ")})" : ""
    end

    # A person comes by sign-in; one whose email is someone else's here would be two people at once.
    def people
      reasons = []
      @source.each("users") do |row|
        next if Workspace::Import::People.here(row)
        reasons << "#{row["email"]} is someone else here, who signs in another way" if Workspace::Import::People.other(row)
      end
      reasons
    end

    def secrets
      [ Workspace::Import::People::TABLE, *Workspace::Import::Table.all ].flat_map do |table|
        table.encrypted_columns(@source).filter_map do |column|
          unreadable = @source.values(table.name, column).count { !readable?(it) }
          "#{table.name}.#{column}: #{unreadable} value(s) cannot be read with the keys given; are they the other install's?" if unreadable.positive?
        end
      end
    end

    def readable?(ciphertext)
      @keys.decrypt(ciphertext)
      true
    rescue ActiveRecord::Encryption::Errors::Decryption, ActiveRecord::Encryption::Errors::Encoding
      false
    end

    # A store from another moment than the database would carry threads that
    # do not match their messages, or none at all.
    def threads
      return [] unless @source.store
      missing = @source.values("conversations", "durable_id").map(&:to_s) - @source.threads
      missing.any? ? [ "#{@source.store.basename} does not hold #{missing.size} thread(s) the database names (#{missing.first(5).join(", ")}): make both copies from one stopped install" ] : []
    end

    def files
      missing = []
      @source.each("active_storage_attachments") do |row|
        next unless Workspace::Import::Table.for_record_type(row["record_type"])
        blob = @source.find("active_storage_blobs", row["blob_id"])
        missing << (blob ? blob["key"] : "blob #{row["blob_id"]}") unless blob && @source.file(blob["key"]).file?
      end
      missing.any? ? [ "#{missing.size} attached file(s) missing from the copy's folder: #{missing.first(5).join(", ")}" ] : []
    end
end
