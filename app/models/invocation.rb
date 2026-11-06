# The one ledger of tool calls. The sidecar replays a call after a crash
# (Pi Durable runs `replay: 'safe'` tools again), so each call is one row per
# (conversation, task, call): a repeat returns what was recorded, a changed
# repeat is a conflict, and a database tool's work commits with its result.
# An outside call (`effect :external`) commits that it is running, then goes
# out with no transaction open, so a slow server holds no write lock.
class Invocation < ApplicationRecord
  class Conflict < StandardError; end

  STATES = %w[ pending awaiting_person approved running denied succeeded failed ].freeze
  CALL_ID = %r{\A[\w.:|+/=-]{1,512}\z}
  WAIT = 1.day # the sidecar's own wait bound (agent/runtime.mjs humanTimeoutMs)
  # An outside call still running after this was lost to a crash before its
  # result was recorded. It runs again: MCP has no idempotency key, so an outside
  # call is at least once, not exactly once (PARITY.md §7).
  RUN_LIMIT = 5.minutes

  belongs_to :conversation
  has_one :approval, dependent: :destroy
  has_one :answer, dependent: :destroy

  enum :state, STATES.index_by(&:itself), default: :pending
  delegate :bot, :user, to: :conversation

  after_commit :show_progress, on: %i[ create update ]

  # The digest binds the whole call (who, which bot, which conversation, which
  # call, which arguments), so a replay cannot move a call elsewhere.
  def self.digest_for(conversation, task_id:, call_id:, tool:, arguments:)
    Agent::Canonical.digest("actorId" => conversation.user_id.to_s, "workspaceId" => conversation.bot_id.to_s,
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
    perform_outside if @claimed
    outcome
  end

  def outcome
    case state
    when "succeeded" then { status: "done", result: result, isError: false }
    when "failed" then { status: "done", result: { error: error }, isError: true }
    # Named, so a code mode script that made several calls knows which one.
    when "denied" then { status: "done", result: { error: "#{approval&.decided_by || 'The person'} declined #{tool_name} #{arguments.to_json}." }, isError: true }
    # Rails names the wait, and rings the doorbell under the same name.
    else { status: "waiting", key: wait_key, expiresAt: expires_at&.iso8601(3) }
    end
  end

  def approve!(by:) = decide!("approve", by: by)
  def deny!(by:) = decide!("deny", by: by)

  def answer!(selections:, text:, by:)
    settle_person { create_answer!(selections: selections, text: text.to_s, decided_by: by) && approved! }
  end

  def asks = tool_class&.asks

  def answerable? = awaiting_person? && expires_at&.future?

  # The sidecar's name for the wait this call holds (agent/extensions.mjs).
  def wait_key = "#{task_id}:#{call_id}"

  def tool_class = bot.tool(tool_name)

  # The page element for this call, named by the model's call id so the
  # assistant message that made the call can hold it before this row exists.
  def self.dom_target(call_id) = "tool_call_#{Digest::SHA256.hexdigest(call_id.to_s).first(16)}"
  def dom_target = self.class.dom_target(call_id)

  # A call made inside another is named under it, `<parent>/<own>`: a code
  # mode script's calls (`<script>/c<n>`), a helper's (`<helper>/<call>`), a
  # script a helper ran (`<helper>/<script>/c<n>`). One rule for all three.
  def self.parent_call_id(call_id) = call_id.to_s.rpartition("/").first.presence
  def parent_call_id = self.class.parent_call_id(call_id)

  # The line a nested call is listed in: the outermost, the call the bot's
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

    def begin_work
      return fail_with("#{tool_name} is not one of this bot's tools.") unless tool_class
      problems = tool_class.errors_for(arguments)
      return fail_with("Invalid arguments: #{problems.to_sentence}") if problems.any?
      return fail_with("#{tool_name} is not available here.") unless tool.permitted?
      return update!(state: :awaiting_person, expires_at: WAIT.from_now) if asks
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
    def claim
      update!(state: :running, updated_at: Time.current)
      @claimed = true
    end

    def perform_outside
      @claimed = false
      result = tool.call(**arguments.symbolize_keys)
      with_lock { update!(state: :succeeded, result: result) if running? }
    rescue Tool::Refusal => refusal
      with_lock { fail_with(refusal.message) if running? }
    end

    def fail_with(message)
      update!(state: :failed, error: message.to_s.truncate(1_000))
    end

    def decide!(decision, by:)
      settle_person do
        create_approval!(decision: decision, decided_by: by)
        update!(state: decision == "approve" ? :approved : :denied)
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
