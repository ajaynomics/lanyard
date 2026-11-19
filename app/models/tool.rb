# A tool is what the model may ask the app to do for a person. Each one is a
# small class: one JSON Schema for its arguments, its own rules for who may use
# it and whether a person must answer first, and a `call` that delegates to the
# domain. Tool calls arrive through Invocation, the one ledger that makes a
# call replayed by the sidecar after a crash run once.
#
#   class Tool::RememberNote < Tool
#     description "Save or replace a note by key."
#     argument :key, :string, max_length: 64
#     def call(key:) = agent.notes.remember(key, ...)
#   end
class Tool
  # A refusal the model should read and can act on, rather than a crash.
  class Refusal < StandardError; end

  # What an agent may tell the person approving a call, beside what it asks
  # to do (#169): their earlier words, or what is still open. The card shows
  # it as the agent's; the call never gets it (Invocation#action_arguments).
  NOTE = "note_to_approver"
  NOTE_DESCRIPTION = "Optional: a short note for the person approving, shown on the card above what you ask to do and never sent. " \
    "Quote their earlier words or list open questions here."

  class << self
    def tool_name = name.demodulize.underscore

    def description(text = nil)
      text ? @description = text : @description
    end

    # nil (just run), :approval (a person allows or denies the exact call) or
    # :question (the call waits for a person's answer, which is its result).
    # always: false when a person must allow every call, never "Always".
    # every_time: true when a person allows every call even where the
    # workspace's approval policy allows everything (APP__APPROVALS=allow, or
    # "others"): what goes out in the person's own name, as an iMessage from
    # their phone.
    # even_approving_everything: true when it asks even where the workspace's
    # policy approves everything (Workspace::ApprovalPolicy): a routine, a
    # connector's mail send and event delete (McpServer::Google).
    def asks(kind = nil, always: true, every_time: false, even_approving_everything: false)
      return @asks unless kind
      every_time ||= even_approving_everything
      @asks, @always, @every_time, @even_approving_everything = kind, always && !every_time, every_time, even_approving_everything
      argument NOTE, :string, required: false, max_length: 1_000, description: NOTE_DESCRIPTION if kind == :approval
    end

    def notes_to_approver? = arguments.key?(NOTE)

    def always? = @always != false
    def every_time? = @every_time == true
    def even_approving_everything? = @even_approving_everything == true

    # Marks a tool whose call reaches other people or another account: a
    # message, an invitation or a sign-in. Where its workspace approves
    # everything none of these ask, so Permissions names them; on the normal
    # policy each asks (Workspace::ApprovalPolicy).
    def reaches_others = @reaches_others = true
    def reaches_others? = @reaches_others == true

    # Marks a tool whose call changes the agent itself, so a workspace on the
    # normal approval policy asks first, as for what reaches others
    # (Workspace::ApprovalPolicy).
    def changes_itself = @changes_itself = true
    def changes_itself? = @changes_itself == true

    # Marks a tool a person may still answer "Always" for exactly the call's
    # recipients where it otherwise asks every time, never for every call: the
    # Always then covers a later call only if it reaches no one else (#150).
    def always_with_recipients = @always_with_recipients = true
    def always_with_recipients? = @always_with_recipients == true

    # Whether the install has what the tool needs; a picked tool it hasn't is
    # neither offered to the agent nor listed in its settings.
    def available? = true

    # Its name in the agent's settings.
    def label = tool_name.humanize

    # :database (the work commits with its record, so it runs exactly once) or
    # :external (the call leaves this database: the ledger commits that it is
    # running first, and makes the call outside any transaction).
    def effect(kind = nil)
      kind ? @effect = kind : (@effect || :database)
    end

    # An outside call whose second run is the same as its first (a message
    # keyed by the call), so one lost to a crash may be made again rather
    # than failed (Invocation::RUN_LIMIT).
    def safe_to_repeat = @safe_to_repeat = true
    def safe_to_repeat? = @safe_to_repeat || false

    # One JSON Schema property. Keywords are JSON Schema's, in Ruby case
    # (max_length: becomes maxLength). Patterns must be ECMA-262: the sidecar
    # checks the same schema in JavaScript.
    def argument(name, type, required: true, **keywords)
      arguments[name.to_s] = { "type" => type.to_s, **keywords.to_h { |key, value| [ key.to_s.camelize(:lower), value ] } }.deep_stringify_keys
      required_arguments << name.to_s if required
    end

    # An argument listing paths on the agent's computer: the sidecar reads
    # those files and hands them over (Upload) before the call, refusing any
    # over `each` bytes, or over `total` together. Limits are settings, so
    # given as blocks, read when the tool is declared.
    def reads_files(argument, each:, total:)
      @reads_files = { argument: argument.to_s, each: each, total: total }
    end

    def files_limits = @reads_files&.then { { each: it[:each].call, total: it[:total].call } }

    def arguments = @arguments ||= {}
    def required_arguments = @required_arguments ||= []

    def schema
      { "type" => "object", "additionalProperties" => false, "properties" => arguments, "required" => required_arguments }
    end

    def errors_for(values)
      JSONSchemer.schema(schema, regexp_resolver: "ecma").validate(values).map { it["error"] }
    end

    def declaration
      files = @reads_files && { argument: @reads_files[:argument], maxBytes: files_limits[:each], maxTotalBytes: files_limits[:total] }
      { name: tool_name, description: description, parameters: schema, files: files }.compact
    end
  end

  attr_reader :invocation
  delegate :conversation, :agent, :user, to: :invocation

  def initialize(invocation)
    @invocation = invocation
  end

  # The call's own arguments, the same whether the model called this tool
  # directly or through use_tool (Tool::UseTool), which passes them on. The
  # #invocation is the ledger's own row either way, so an association, a query
  # or a job argument gets the record itself (#253).
  def arguments = invocation.call_arguments

  # Whether the sidecar fills the browser after this call (Tool::SignInWithSavedPassword).
  def self.fills? = false
  # Whether it types a payment's card in after this call (Tool::PayByCard).
  def self.pays? = false
  # Whether its answer names a file the sidecar saves on the agent's computer,
  # its bytes fetched with #download (Invocation#file?, Tool::ImessageAttachment).
  def self.saves_file? = false

  # Whether its card shows what the call will do, fetched from outside, rather
  # than its arguments, and binds the approval to it (Invocation#fetch_preview).
  def previews? = false

  # Whether a person answers first; a tool may decide by its arguments (Tool::SendEmail).
  def asks = self.class.asks

  # A tool's own condition beyond the agent listing it, checked before it runs
  # and again after a person approves.
  def permitted? = true

  # Why the call can't work whatever a person answers, or nil: then it is
  # refused before anyone is asked (Tool::UseTool's, with files).
  def refusal = nil

  # Whether a person may answer this tool "Always" (Permission), the name it is
  # granted under, and whom a call reaches, for "Always with" them: none for a
  # tool that reaches no one in particular. Read from the call as recorded.
  def always? = self.class.always?
  def every_time? = self.class.every_time?
  def even_approving_everything? = self.class.even_approving_everything?
  def always_with_recipients? = self.class.always_with_recipients?
  def reaches_others? = self.class.reaches_others?
  def changes_itself? = self.class.changes_itself?
  def always_label = "Always with #{recipients.to_sentence}"
  def permission_name = invocation.call_name

  # The one person who may allow the call, where only one may; otherwise any
  # member of its agent's workspace (Tool::ChangeYourself, for its workspace's).
  def approver = nil
  def recipients = []

  # Whom a call reaches by address or number, which a member of the workspace
  # may have closed to all its agents but one (Workspace::Membership#sole_contact).
  def contacts = recipients

  # Why it may not reach them, whatever a person answers or the install
  # allows: checked before anyone is asked, and again before it goes.
  def contact_refusal = agent.workspace.barred_member(agent, contacts)&.refusal

  def call(**) = raise NotImplementedError
end
