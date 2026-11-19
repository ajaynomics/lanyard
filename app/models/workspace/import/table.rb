# One table of the copy and how its rows come here (docs/import.md): which
# columns name another record that came, and so take that record's id here;
# what is set afresh; what is dropped, and why; and which rows stay behind.
# Every other column the two releases share is written as stored there,
# except an encrypted one, read with the other install's keys and written
# again under this install's.
class Workspace::Import::Table
  AGENT = { "agent_id" => "agents" }.freeze
  CONVERSATION = { "conversation_id" => "conversations" }.freeze
  INVOCATION = { "invocation_id" => "invocations" }.freeze

  # In order: each after the tables it names, but for a reference filled in once all have come.
  def self.all
    @all ||= [
      new("agents", Agent, references: { "user_id" => "users", "mail_to_agent_id" => "agents" }, set: { "workspace_id" => ->(_, run) { run.workspace.id } }),
      new("agent_revisions", Agent::Revision, references: AGENT),
      new("notes", Note, references: AGENT),
      new("prompts", Prompt, references: AGENT),
      new("skills", Skill, references: AGENT),
      new("skill_bundled_files", Skill::BundledFile, references: { "skill_id" => "skills" }),
      new("documents", Document, references: AGENT.merge("seen_version_id" => "document_versions")),
      new("document_versions", Document::Version, references: { "document_id" => "documents" }),
      new("routines", Routine, references: AGENT),
      new("permissions", Permission, references: AGENT.merge("granted_by_id" => "users")),
      new("computers", Computer, references: AGENT,
        drop: { "ssh_keyring" => "an SSH key held by the other install's sidecar; the agent's own key here is used instead" }),
      new("concourse_agents", ConcourseAgent, references: AGENT.merge("bridge_approved_by_id" => "users")),
      new("campfire_bots", CampfireBot, references: AGENT),
      new("telegram_bots", TelegramBot, references: AGENT),
      new("telegram_messages", TelegramMessage, references: { "telegram_bot_id" => "telegram_bots" }),
      new("agent_mail_accounts", Agent::MailAccount, references: AGENT),
      new("agent_mail_account_folders", Agent::MailAccount::Folder, references: { "mail_account_id" => "agent_mail_accounts" }),
      new("agent_calendar_servers", Agent::CalendarServer, references: AGENT),
      # The other sidecar's thread is carried after (Workspace::Import::Threads), under an id of this sidecar's.
      new("conversations", Conversation, references: { "user_id" => "users", "agent_id" => "agents", "parent_id" => "conversations", "root_id" => "conversations" },
        set: { "forked_at_entry_id" => ->(row, run) { run.entries.id(row["forked_at_entry_id"]) } },
        drop: { "durable_id" => "the other sidecar's id for the thread; it is carried into this sidecar under one of its own (Threads below)",
                "last_entry_id" => "how far the other sidecar's thread was read; the carried thread is read from where it was carried" }),
      # Only the owner's own, switched on, with their settings and which
      # agents use them: a connector holds the credentials of whoever set it
      # up, and in a shared workspace every member reaches it. Nothing it
      # signed in with or was given comes (Reconnect): the owner reconnects it here.
      new("mcp_servers", McpServer, references: { "user_id" => "users", "conversation_id" => "conversations" },
        set: { "workspace_id" => ->(_, run) { run.workspace.id },
               "sign_in_needed" => ->(row, _) { Workspace::Import::Reconnect.signs_in?(row) },
               "refresh_error" => ->(row, _) { Workspace::Import::Reconnect.problem(row) } },
        drop: Workspace::Import::Reconnect::SIGN_IN.index_with { "a sign-in through the other install's OAuth client; the owner signs in again here" }
          .merge(Workspace::Import::Reconnect::KEYS.index_with { "a key the owner gave the other install; they give it again here" }),
        leave: ->(row, owner) do
          if row["install"] then "the other install's own connector to its wiki or CRM: a workspace here turns on this install's own"
          elsif row["user_id"] != owner then "another person's: the owner imports only their own"
          elsif row["enabled"].to_i.zero? then "switched off there"
          end
        end),
      new("core_connectors", Agent::CoreConnector, references: AGENT.merge("mcp_server_id" => "mcp_servers")),
      new("connector_moves", Agent::ConnectorMove, references: AGENT.merge("mcp_server_id" => "mcp_servers")),
      new("messages", Message, references: CONVERSATION.merge("author_id" => "users"),
        set: { "entry_id" => ->(row, run) { run.entries.id(row["entry_id"]) }, "entry_key" => ->(row, run) { run.entries.key(row["entry_key"]) } }),
      new("invocations", Invocation, references: CONVERSATION),
      new("answers", Answer, references: INVOCATION.merge("decided_by_id" => "users")),
      new("approvals", Approval, references: INVOCATION.merge("decided_by_id" => "users")),
      new("payment_requests", PaymentRequest, references: INVOCATION),
      new("uploads", Upload, references: CONVERSATION),
      new("helpers", Helper, references: CONVERSATION),
      # Tasks from before progress notes were passed on, as 20261116080000 marks them.
      new("peer_tasks", PeerTask, references: CONVERSATION.merge("concourse_agent_id" => "concourse_agents"), before: { "notes_followed" => false }),
      new("workflows", Workflow, references: CONVERSATION),
      new("workflow_runs", Workflow::Run, references: { "workflow_id" => "workflows" }),
      new("workflow_steps", Workflow::Step, references: { "run_id" => "workflow_runs" }),
      new("held_emails", HeldEmail, references: CONVERSATION.merge(INVOCATION, "cancelled_by_id" => "users"))
    ]
  end

  def self.named(name) = all.find { it.name == name }

  def self.for_record_type(record_type) = all.find { it.model.name == record_type }

  # What the copy holds that is not written here, said plainly.
  def self.not_carried(source)
    [ Workspace::Import::People::TABLE, *all ].select { source.table?(it.name) }.flat_map { it.not_carried(source) }
  end

  attr_reader :name, :model, :references

  def initialize(name, model, references: {}, set: {}, drop: {}, before: {}, leave: nil)
    @name, @model, @references, @set, @drop, @before, @leave = name, model, references, set, drop, before, leave
  end

  def copy(run)
    run.ids(name)
    run.source.each(name) { copy_row(it, run) }
  end

  # Whether a row comes for the owner (the copy's id of them), rather than staying in the copy.
  def comes?(row, owner) = !@leave&.(row, owner)

  def copy_row(row, run)
    reason = @leave&.(row, run.owner)
    return run.leave(name, reason) if reason
    values = values(row, run)
    return run.leave(name, "needs a record that stays in the copy") if values.value?(:missing)
    deferred = values.select { |_, value| value == :deferred }.keys
    id = insert(values.merge(deferred.index_with { nil }))
    run.ids(name)[row["id"]] = id
    deferred.each { run.defer(name, id, it, to: references.fetch(it), source_id: row[it]) }
  end

  # The row as written here, an encrypted column as its plaintext: a
  # reference as the id here of the record it names, or, until that record
  # has come, :deferred; :missing if that record stays behind.
  def values(row, run, final: false)
    columns(run.source).index_with do |column|
      if @set.key?(column) then @set[column].respond_to?(:call) ? @set[column].(row, run) : @set[column]
      elsif @drop.key?(column) then nil
      elsif !row.key?(column) then @before.fetch(column)
      elsif references.key?(column) then reference(column, row[column], run, final:)
      elsif encrypted?(column) then row[column] && run.keys.decrypt(row[column])
      else row[column]
      end
    end
  end

  # The columns written: those both releases have, those set afresh, and
  # those the copy predates that take a value of their own.
  def columns(source)
    (source.columns(name) | @set.keys | @drop.keys | @before.keys) & (model.column_names - %w[ id ])
  end

  def encrypted?(column) = model.encrypted_attributes.to_a.include?(column.to_sym)

  # Those read and written again: a dropped one is never read.
  def encrypted_columns(source) = (source.columns(name) & model.column_names - @drop.keys).select { encrypted?(it) }

  # The plaintext of an encrypted column as written here, under this install's keys.
  def plaintext(column, ciphertext)
    type = encryption(column)
    ciphertext && type.cast_type.serialize(type.deserialize(ciphertext))
  end

  def binary?(column) = model.columns_hash.fetch(column).type == :binary

  def not_carried(source)
    dropped = @drop.select { |column, _| source.columns(name).include?(column) }.map { |column, reason| "#{name}.#{column}: #{reason}" }
    unknown = (source.columns(name) - model.column_names).map { "#{name}.#{it}: no such column at this release" }
    dropped + unknown
  end

  private
    def reference(column, source_id, run, final:)
      return if source_id.nil?
      if (id = run.id(references[column], source_id)) then id
      elsif !final && (references[column] == name || !run.came?(references[column])) then :deferred
      elsif model.columns_hash.fetch(column).null then nil
      else :missing
      end
    end

    def insert(values)
      connection = model.connection
      quoted = values.map do |column, value|
        value = encrypt(column, value) if encrypted?(column)
        connection.quote(binary?(column) && value ? ActiveModel::Type::Binary::Data.new(value) : value)
      end
      connection.insert("INSERT INTO #{connection.quote_table_name(name)} (#{values.keys.map { connection.quote_column_name(it) }.join(", ")}) VALUES (#{quoted.join(", ")})")
    end

    def encrypt(column, plaintext)
      type = encryption(column)
      plaintext && type.serialize(type.cast_type.deserialize(plaintext))
    end

    # The column's encryption, beneath any normalizing: what is carried is
    # what was stored, not what a person would type today.
    def encryption(column)
      type = model.type_for_attribute(column)
      type = type.cast_type until type.is_a?(ActiveRecord::Encryption::EncryptedAttributeType)
      type
    end
end
