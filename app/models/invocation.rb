# The one ledger of tool calls. The sidecar replays a call after a crash
# (Pi Durable runs `replay: 'safe'` tools again), so each call is one row per
# (conversation, task, call): a repeat returns what was recorded, a changed
# repeat is a conflict, and a database tool's work commits with its result.
# An outside call (`effect :external`) commits that it is running and answers
# "waiting"; a job makes the call with no transaction open and rings the
# doorbell, so a slow server holds neither a write lock nor the sidecar's request.
class Invocation < ApplicationRecord
  class Conflict < StandardError; end

  STATES = %w[ pending awaiting_person approved running denied succeeded failed ].freeze
  CALL_ID = %r{\A[\w.:|+/=-]{1,512}\z}
  WAIT = 1.day # the sidecar's own wait bound (agent/runtime.mjs humanTimeoutMs)
  # An outside call still running after this was lost to a crash before its
  # result was recorded. It runs again: MCP has no idempotency key, so an outside
  # call is at least once, not exactly once.
  RUN_LIMIT = 5.minutes
  # How long after a Google tool finds a file the sidecar may fetch it (#download_file).
  FILE_WITHIN = 10.minutes

  belongs_to :conversation
  has_one :approval, dependent: :destroy
  has_one :answer, dependent: :destroy

  enum :state, STATES.index_by(&:itself), default: :pending
  delegate :agent, :user, to: :conversation

  after_commit :show_progress, on: %i[ create update ]
  # After show_progress, which marks the thread waiting, so the notice's badge counts it.
  after_commit :notify_person, on: %i[ create update ], if: -> { saved_change_to_state?(to: "awaiting_person") }
  after_commit :preview_later, on: %i[ create update ], if: -> { awaiting_person? && preview.nil? && tool_class && tool.previews? }

  # The digest binds the whole call (who, which agent, which conversation, which
  # call, which arguments), so a replay cannot move a call elsewhere.
  def self.digest_for(conversation, task_id:, call_id:, tool:, arguments:)
    Agent::Canonical.digest("actorId" => conversation.user_id.to_s, "workspaceId" => conversation.agent_id.to_s,
      "conversationId" => conversation.durable_id, "taskId" => task_id, "callId" => call_id, "tool" => tool, "arguments" => arguments)
  end

  def self.receive(conversation, task_id:, call_id:, tool:, arguments:, digest:)
    raise Conflict unless (task_id.is_a?(Integer) || (task_id.is_a?(String) && task_id.match?(CALL_ID))) &&
      call_id.is_a?(String) && call_id.match?(CALL_ID) && tool.is_a?(String) && arguments.is_a?(Hash)
    expected = digest_for(conversation, task_id: task_id, call_id: call_id, tool: tool, arguments: arguments)
    raise Conflict unless digest.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(expected, digest)

    invocation = conversation.invocations.create_or_find_by!(task_id: task_id.to_s, call_id: call_id) do
      it.tool_name = tool
      it.arguments = arguments
      it.digest = expected
    end
    raise Conflict unless invocation.digest == expected
    invocation.advance
  end

  # Moves the call as far as it can go now, and says where it stands.
  # SQLite's immediate transactions serialise competing replays here.
  def advance
    with_lock do
      case state
      when "pending" then begin_work
      when "approved" then perform
      when "running" then perform if updated_at < RUN_LIMIT.ago
      when "awaiting_person" then fail_with("Nobody answered in time.") if expires_at&.past?
      end
    end
    InvocationCallJob.perform_later(self) if @claimed
    outcome
  end

  def outcome
    case state
    when "succeeded" then { status: "done", result: result, isError: false, fill: (true if tool_class.try(:fills?)), file: (true if file?) }.compact
    when "failed" then { status: "done", result: { error: error }, isError: true }
    # Named, so a code mode script that made several calls knows which one.
    when "denied" then { status: "done", result: { error: "#{approval&.decided_by || 'The person'} declined #{tool_name} #{arguments.to_json}." }, isError: true }
    # Rails names the wait, and rings the doorbell under the same name.
    else { status: "waiting", key: wait_key, expiresAt: expires_at&.iso8601(3) }
    end
  end

  # The password for a fill that was cleared to run, once and soon after
  # (Tool::SignInWithSavedPassword). Nil when it was used, is too old, or was
  # never cleared; the password manager is asked again each time.
  def redeem_sign_in
    with_lock do
      return unless succeeded? && tool_class.try(:fills?) && result.is_a?(Hash) && !result.key?("filled") &&
        cleared_at&.after?(Tool::SignInWithSavedPassword::FILL_WITHIN.ago)
      update!(result: result.merge("filled" => true))
    end
    DurableAssistants::Passbolt.sign_in(agent, DurableAssistants::Passbolt.find_by_name(agent, arguments["name"]).id)
  end

  # A Google tool's file (McpServer::Google::FILES), for the sidecar to save
  # on the agent's computer: named in the result, its bytes fetched from
  # Google again, and only soon after the call, as a fill's password is.
  def file?
    succeeded? && result.is_a?(Hash) && result["file"].is_a?(Hash) && google_file_tool.present?
  end

  def download_file
    return unless file? && updated_at.after?(FILE_WITHIN.ago)
    McpServer::Google.new(google_file_tool.server).download(google_file_tool.listing["name"], call_arguments)
  end

  # always: "agent" (every call of this tool) or "recipient" (calls reaching
  # only this call's recipients) remembers the answer (Permission).
  def approve!(by:, always: nil)
    raise ArgumentError, "#{always} is not offered for #{tool_name}" if always && !always_choices.include?(always)
    raise Conflict unless approvable?
    decide!("approve", by: by) { remember(always, by) if always }
  end

  def deny!(by:) = decide!("deny", by: by)

  # The "Always" answers a person may give this call: with its recipients,
  # when it has any, and for every call of its tool.
  def always_choices
    return [] unless asks == :approval && tool.always?
    [ ("recipient" if tool.recipients.any?), "agent" ].compact
  end

  def recipients = tool.recipients

  # A card that shows what the call will do (Tool#previews?) can be allowed
  # only once that has been fetched; it can always be denied.
  def approvable? = !(tool_class && tool.previews?) || preview&.key?("digest")

  # Fetches what the card shows, outside any transaction (InvocationPreviewJob).
  # A failure is shown on the card, which can then only be denied.
  def fetch_preview
    return unless awaiting_person? && tool.previews?
    shown = begin
      tool.preview
    rescue McpServer::SignInNeeded, DurableAssistants::Google::Error, Mail::Field::ParseError => problem
      { "error" => problem.message.truncate(300) }
    end
    with_lock { update!(preview: shown) if awaiting_person? && preview.nil? }
  end

  # When the call was let run: the person's approval, or, on an install that
  # allows everything (Agent#allows?), the call itself, which ran at once.
  def cleared_at
    approval&.created_at || (created_at if agent.allows?(tool))
  end

  def answer!(selections:, text:, by:)
    settle_person { create_answer!(selections: selections, text: text.to_s, decided_by: by) && approved! }
  end

  def asks = tool_class && tool.asks

  # The card's title, as the thread shows it (invocations/_invocation): what a
  # notice says the agent needs. The tool's name, never its arguments, except
  # a question, which is the agent's words to the person.
  def card_title
    case asks
    when :question then arguments["question"].to_s
    when :sign_in then "Save a sign-in for #{agent}?"
    else "Allow #{tool_name == "use_tool" ? ApplicationController.helpers.tool_label("use_tool", arguments) : tool_name.humanize(capitalize: false)}?"
    end
  end

  def answerable? = awaiting_person? && expires_at&.future?

  # A claimed outside call, made by InvocationCallJob with no transaction
  # open. Its result is recorded only if the call is still this one's to
  # finish; a run lost past RUN_LIMIT may have been claimed again.
  def call_outside
    return unless running?
    raise Tool::Refusal, "#{tool_name} is no longer available." unless tool_class
    return if changed_since_approved?
    result = tool.call(**arguments.symbolize_keys)
    with_lock { update!(state: :succeeded, result: result) if running? }
  rescue Tool::Refusal => refusal
    with_lock { fail_with(refusal.message) if running? }
  rescue => error
    # Any other error fails the call too, never leaves it running: a running
    # call is claimed and made again after RUN_LIMIT, so an email whose server
    # failed after accepting it would go out again every five minutes.
    Rails.error.report(error, context: { invocation_id: id, tool: tool_name })
    with_lock { fail_with("#{tool_name} failed (#{error.class}). It may or may not have happened; check before trying again.") if running? }
  end

  # The sidecar's name for the wait this call holds (agent/extensions.mjs).
  def wait_key = "#{task_id}:#{call_id}"

  def tool_class = conversation.tool(tool_name)

  # The page element for this call, named by the model's call id so the
  # assistant message that made the call can hold it before this row exists.
  def self.dom_target(call_id) = "tool_call_#{Digest::SHA256.hexdigest(call_id.to_s).first(16)}"
  def dom_target = self.class.dom_target(call_id)

  # A call made inside another is named under it, `<parent>/<own>`: a code
  # mode script's calls (`<script>/c<n>`), a helper's (`<helper>/<call>`), a
  # script a helper ran (`<helper>/<script>/c<n>`). One rule for all three.
  def self.parent_call_id(call_id) = call_id.to_s.rpartition("/").first.presence
  def parent_call_id = self.class.parent_call_id(call_id)

  # The line a nested call is listed in: the outermost, the call the agent's
  # reply made, which is always on the page. A line in between (a script a
  # helper ran) is live only and redrawn as it runs, so what is listed inside
  # it would be lost.
  def self.line_call_id(call_id) = (call_id.to_s.split("/").first if parent_call_id(call_id))

  def trace_status
    case state
    when "succeeded" then "done"
    when "failed", "denied" then "error"
    when "awaiting_person" then "pending"
    else "running"
    end
  end

  private
    def tool = @tool ||= tool_class.new(self)

    # The Google tool behind the call, made directly or through use_tool, and
    # of a Tool::Mcp::Group, the chosen account's.
    def google_file_tool
      found = tool_class
      found = found.target(arguments["name"]) if found.is_a?(Tool::UseTool)
      found = found.member(call_arguments) if found.is_a?(Tool::Mcp::Group)
      found if found.is_a?(Tool::Mcp) && found.server.google && McpServer::Google::FILES.include?(found.listing["name"])
    end

    def call_arguments = tool_name == "use_tool" ? arguments["arguments"].to_h : arguments

    def show_progress
      if (line = self.class.line_call_id(call_id))
        # Listed inside its line; appending an element already there replaces it.
        broadcast_append_to conversation, target: "#{self.class.dom_target(line)}_calls", partial: "invocations/invocation", locals: { invocation: self }
      else
        broadcast_replace_to conversation, target: dom_target, partial: "invocations/invocation", locals: { invocation: self }
      end
      conversation.mark("waiting") if awaiting_person?
      conversation.mark("running") if approved? || (denied? && conversation.waiting?)
    end

    def notify_person = conversation.notify_needs_you(self)

    def preview_later = InvocationPreviewJob.perform_later(self)

    # The person approved what the card showed. If it is no longer what would
    # go, that approval is void: the call waits again, on a card showing it now.
    def changed_since_approved?
      return false unless preview&.key?("digest") && tool.previews?
      now = begin
        tool.preview
      rescue McpServer::SignInNeeded, DurableAssistants::Google::Error, Mail::Field::ParseError => problem
        raise Tool::Refusal, "Couldn't check the draft again before sending, so it wasn't sent: #{problem.message}"
      end
      return false if now["digest"] == preview["digest"]
      with_lock do
        next unless running?
        approval&.destroy!
        self.approval = nil
        update!(state: :awaiting_person, preview: now.merge("changed" => true), expires_at: WAIT.from_now)
      end
      true
    end

    def begin_work
      return fail_with("#{tool_name} is not one of this agent's tools.") unless tool_class
      problems = tool_class.errors_for(arguments)
      return fail_with("Invalid arguments: #{problems.to_sentence}") if problems.any?
      return fail_with("#{tool_name} is not available here.") unless tool.permitted?
      # What the agent calls of what find_tools found becomes its own tool from the next message; calling it again keeps it.
      called = tool_name == "use_tool" ? arguments["name"] : tool_name
      conversation.activate([ called ]) if tool_name == "use_tool" || conversation.activated_tools.include?(called)
      return update!(state: :awaiting_person, expires_at: WAIT.from_now) if asks && !(asks == :approval && agent.allows?(tool))
      perform
    end

    def perform
      return fail_with("#{tool_name} is no longer available.") unless tool_class && tool.permitted?
      return claim if tool_class.effect == :external
      update!(state: :succeeded, result: tool.call(**arguments.symbolize_keys))
    rescue Tool::Refusal, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => refusal
      fail_with(refusal.message)
    end

    # A replay that arrives meanwhile is told to wait, rather than calling again.
    # The sidecar holds that wait as it holds a person's (CONTRACT.md).
    def claim
      update!(state: :running, updated_at: Time.current)
      @claimed = true
    end

    def fail_with(message)
      update!(state: :failed, error: message.to_s.truncate(1_000))
    end

    def decide!(decision, by:)
      settle_person do
        create_approval!(decision: decision, decided_by: by)
        yield if block_given?
        update!(state: decision == "approve" ? :approved : :denied)
      end
    end

    def remember(always, by)
      (always == "agent" ? [ "" ] : tool.recipients).each do |recipient|
        agent.permissions.create_or_find_by!(tool_name: tool.permission_name, recipient: recipient) { it.granted_by = by }
      end
    end

    # The decision commits first; only then does a job ring the sidecar's
    # doorbell. No network call happens inside this transaction.
    def settle_person(&decision)
      with_lock do
        raise Conflict unless answerable?
        decision.call
      end
      InvocationWakeJob.perform_later(self)
    end
end
