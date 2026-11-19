# The one ledger of tool calls. The sidecar replays a call after a crash
# (Pi Durable runs `replay: 'safe'` tools again), so each call is one row per
# (conversation, task, call): a repeat returns what was recorded, a changed
# repeat is a conflict, and a database tool's work commits with its result.
# An outside call (`effect :external`) commits that it is running and answers
# "waiting"; a job makes the call with no transaction open and rings the
# doorbell, so a slow server holds neither a write lock nor the sidecar's request.
class Invocation < ApplicationRecord
  class Conflict < StandardError; end
  # Someone other than the one person who may allow this call (Tool#approver).
  class NotTheApprover < StandardError; end

  STATES = %w[ pending awaiting_person approved running denied succeeded failed ].freeze
  CALL_ID = %r{\A[\w.:|+/=-]{1,512}\z}
  WAIT = 1.day # the sidecar's own wait bound (agent/runtime.mjs humanTimeoutMs)
  # An outside call still running this long after its job began it was lost
  # to a crash before its result was recorded, perhaps after it happened. It
  # fails rather than runs again: MCP has no idempotency key, so a second run
  # could be a second email, text or post. The agent can look for its effect
  # and try again. Only a tool whose repeat is the same call
  # (Tool.safe_to_repeat) runs again.
  RUN_LIMIT = 5.minutes
  LOST = "The call stopped before its result was saved, so whether it happened is unknown. Check before trying again."
  # A call whose job has not begun it has not happened, so it waits for a busy
  # job role this long (#overdue) rather than being lost after RUN_LIMIT.
  QUEUE_LIMIT = 30.minutes
  NEVER_STARTED = "The call waited too long to start and was never made. Try again if it still matters."
  WITHDRAWN = "The agent withdrew the question."
  # An approval card the agent that raised it took back (Tool::WithdrawCard,
  # #251), because it replaced the call or no longer wants it.
  WITHDRAWN_CARD = "The agent withdrew this request before anyone answered it, so it did not run."
  # How long after a tool finds a file the sidecar may fetch it (#download_file).
  FILE_WITHIN = 10.minutes

  belongs_to :conversation
  has_one :approval, dependent: :destroy
  has_one :answer, dependent: :destroy
  # A payment's own record, made when the call starts to wait (Tool::PayByCard).
  has_one :payment_request, dependent: :destroy
  # Mail allowed outside its agent's sending hours, waiting for them (Tool::SendEmail).
  has_one :held_email, dependent: :destroy
  # What it handed to an outside provider, recorded before it asked (Dispatch::TOOLS).
  has_one :dispatch, dependent: :destroy
  has_one :sign_in_link, dependent: :delete
  # The whole of what a call found, waiting for the sidecar to save it on the
  # agent's computer (#download_file): an answer too long to read whole
  # (Tool::Mcp::LongAnswer), the bytes a connector sent in its answer
  # (Tool::Mcp::FoundFile), and the files mail brought (ReceivedMail::Files).
  # Kept in Active Storage rather than in result, which the page shows and
  # the sidecar reads back on every replay, and only until the sidecar may
  # no longer fetch them (#hold_file).
  has_many_attached :held_files

  enum :state, STATES.index_by(&:itself), default: :pending
  delegate :agent, :user, :workspace, to: :conversation

  after_commit :show_progress, on: %i[ create update ]
  # The badge counts cards, so each one starting or stopping waiting changes it.
  after_commit -> { conversation.broadcast_badge }, on: %i[ create update ], if: -> { "awaiting_person".in?(saved_change_to_state.to_a) }
  # After show_progress, which shows the thread waiting, so the notice's badge counts it.
  after_commit :notify_person, on: %i[ create update ], if: -> { saved_change_to_state?(to: "awaiting_person") }
  after_commit :preview_later, on: %i[ create update ], if: -> { awaiting_person? && preview.nil? && tool_class && tool.previews? }
  # A payment waits on the person in Link's app, so it is sent there as soon as it waits.
  after_commit -> { PaymentRequest.open!(self) }, on: %i[ create update ], if: -> { saved_change_to_state?(to: "awaiting_person") && asks == :payment }
  # A call handed back (#hand_back) is told to the agent once it ends, however it ends.
  after_commit -> { InvocationReportJob.perform_later(self) }, on: :update, if: -> { handed_back_at && saved_change_to_state? && finished? && !withdrawn? }

  # Calls a person may still allow or deny, oldest first: not questions,
  # sign-ins or payments, which have their own cards.
  def self.waiting_for_approval
    awaiting_person.where(expires_at: Time.current..).includes(:approval, conversation: :agent).order(:created_at).select { it.asks == :approval }
  end

  # Every card waiting on the person, oldest first: approvals, questions,
  # sign-ins and payments alike (ApprovalsController, the phone's Needs you).
  def self.waiting_on_person
    awaiting_person.where(expires_at: Time.current..).includes(:approval, conversation: :agent).order(:created_at).select(&:asks)
  end

  # The digest binds the whole call (who, which agent, which conversation, which
  # call, which arguments), so a replay cannot move a call elsewhere.
  def self.digest_for(conversation, task_id:, call_id:, tool:, arguments:)
    Agent::Canonical.digest("actorId" => conversation.agent.user_id.to_s, "workspaceId" => conversation.agent_id.to_s,
      "conversationId" => conversation.durable_id, "taskId" => task_id, "callId" => call_id, "tool" => tool, "arguments" => arguments)
  end

  def self.receive(conversation, task_id:, call_id:, tool:, arguments:, digest:, hand_back: false)
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
    invocation.advance(hand_back: hand_back)
  end

  # An outside call still running once the sidecar's own wait has ended: its run
  # was cancelled or ended mid-call, so no replay comes to settle it (#advance).
  # Lost, never run again; each is logged.
  def self.settle_abandoned
    running.where(updated_at: ...WAIT.ago).find_each do |invocation| # tenancy-ok: the recurring sweep covers every conversation
      settled = invocation.with_lock { invocation.update!(state: :failed, error: "#{invocation.tool_name}: #{LOST}") if invocation.running? }
      Rails.logger.info "Settled invocation #{invocation.id} (#{invocation.tool_name}) of conversation #{invocation.conversation_id} as lost" if settled
    end
  end

  # A handed-back card nobody answered: it ends, and the agent is told.
  def self.settle_handed_back
    awaiting_person.where.not(handed_back_at: nil).where(expires_at: ...Time.current).find_each(&:advance) # tenancy-ok: the recurring sweep covers every conversation
  end

  # Moves the call as far as it can go now, and says where it stands.
  # SQLite's immediate transactions serialise competing replays here.
  # `hand_back`: the sidecar asks to stop waiting on this call's card.
  def advance(hand_back: false)
    with_lock do
      case state
      when "pending" then begin_work
      when "approved" then perform
      when "running" then overdue
      when "awaiting_person" then fail_with("Nobody answered in time.") if expires_at&.past?
      end
      update!(handed_back_at: Time.current) if hand_back && awaiting_person? && !handed_back_at && hands_back?
    end
    InvocationCallJob.perform_later(self) if @claimed
    outcome
  end

  def outcome
    # Rails' to finish now, the agent told with a message (#report), on every replay too.
    # A question asked without waiting names itself, however it has ended since.
    return { status: "done", result: tool.asked, isError: false } if asked_later?
    # The card's own id goes with it, so an agent that replaces this call can
    # withdraw the card it left open (Tool::WithdrawCard).
    return { status: "handedBack", key: wait_key, card: id } if handed_back_at && !finished?
    case state
    when "succeeded" then { status: "done", result: result, isError: false, fill: (true if called.try(:fills?)), file: (true if file?),
      pay: (true if called.try(:pays?)) }.compact
    when "failed" then { status: "done", result: { error: error }, isError: true }
    # Named, so a code mode script that made several calls knows which one.
    when "denied" then { status: "done", result: { error: "#{approval&.decided_by || 'The person'} declined #{tool_name} #{arguments.to_json}." }, isError: true }
    # Rails names the wait, and rings the doorbell under the same name.
    else { status: "waiting", key: wait_key, expiresAt: expires_at&.iso8601(3) }
    end
  end

  # The password for a fill that was cleared to run, once and soon after
  # (Tool::SignInWithSavedPassword). Nil when it was used, is too old, was
  # never cleared, or its own mail or calendar account uses it now
  # (Agent#reserved_sign_in?); the password manager is asked again each time.
  def redeem_sign_in
    with_lock do
      return if agent.reserved_sign_in?(call_arguments["name"])
      return unless succeeded? && called.try(:fills?) && result.is_a?(Hash) && !result.key?("filled") &&
        cleared_at&.after?(Tool::SignInWithSavedPassword::FILL_WITHIN.ago)
      update!(result: result.merge("filled" => true))
    end
    DurableAssistants::Passbolt.sign_in(agent, DurableAssistants::Passbolt.find_by_name(agent, call_arguments["name"]).id)
  end

  # The approved card, for the sidecar to type into the checkout page, once
  # and soon after the call ran (Tool::PayByCard): nil when it was used, is too
  # old, or there is no approved card. Link is asked for it each time; it is
  # never kept.
  def redeem_card
    payment = with_lock do
      next unless succeeded? && called.try(:pays?) && result.is_a?(Hash) && !result.key?("filled") &&
        updated_at.after?(Tool::SignInWithSavedPassword::FILL_WITHIN.ago) && payment_request&.approved?
      update!(result: result.merge("filled" => true))
      payment_request
    end
    payment&.card
  end

  # Link's answer to a payment, as a person's decision here would be: the
  # call runs, is declined, or fails, and the sidecar is told.
  def settle_payment!(outcome, error = nil)
    settle_person do
      case outcome
      when :approved then update!(state: :approved)
      when :declined then update!(state: :denied)
      else fail_with(error)
      end
    end
  end

  # A file a Google tool (McpServer::Google::FILES), the office's wiki
  # (McpServer::WikiAttachment) or one of the catalogue's (Tool.saves_file?)
  # found, or the files a connector's answer or a message carried
  # (#found_files), for the sidecar to save on the agent's computer: named
  # in the result, their bytes fetched again, and only soon after the call,
  # as a fill's password is.
  def file?
    succeeded? && result.is_a?(Hash) && (found_files.any? ||
      (result["file"].is_a?(Hash) && (called.try(:saves_file?) || mcp_file_tool.present?)))
  end

  # A file's bytes, by its place in found_files (the one file otherwise): a
  # String, or a Tempfile for one too big to hold.
  def download_file(index = 0)
    return unless file? && updated_at.after?(FILE_WITHIN.ago)
    return found_download(index) if found_files.any?
    return unless index.zero?
    return tool.download(**call_arguments.symbolize_keys, file: result["file"]) if called.try(:saves_file?)
    server = mcp_file_tool.server
    return McpServer::WikiAttachment.new(server).download(call_arguments, conversation: conversation) unless server.google
    McpServer::Google.new(server).download(mcp_file_tool.listing["name"], call_arguments)
  end

  # Holds what the call found for the sidecar, purged once it may no longer
  # fetch it. Purging after FILE_WITHIN, not after the first fetch, lets a
  # sidecar whose write failed partway fetch it again. Its place among the
  # call's held files, which found_files names it by.
  def hold_file(io:, filename:, content_type:)
    held_files.attach(io: io, filename: filename, content_type: content_type)
    InvocationFilePurgeJob.set(wait: FILE_WITHIN).perform_later(self)
    held_files.attachments.count - 1
  end

  # always: "agent" (every call of this tool) or "recipient" (calls reaching
  # only this call's recipients) remembers the answer (Permission).
  def approve!(by:, always: nil)
    raise ArgumentError, "#{always} is not offered for #{tool_name}" if always && !always_choices.include?(always)
    raise Conflict unless approvable?
    raise NotTheApprover unless approvable_by?(by)
    decide!("approve", by: by) { remember(always, by) if always }
  end

  def deny!(by:) = decide!("deny", by: by)

  def approvable_by?(person) = !approver || approver == person
  def approver = tool_class && tool.approver

  # The "Always" answers a person may give this call: with its recipients,
  # when it has any, and for every call of its tool. A tool that asks every
  # time offers at most the first (Tool.always_with_recipients). None while
  # the card can't be allowed, as Allow once isn't offered then either.
  def always_choices
    return [] unless asks == :approval && approvable?
    [ ("recipient" if (tool.always? || tool.always_with_recipients?) && tool.recipients.any?), ("agent" if tool.always?) ].compact
  end

  def recipients = tool.recipients
  def always_label = tool.always_label

  # The words an approval card shows: what the call would send, once fetched
  # (Tool#previews?), or else its arguments, as the tool would get them.
  def details
    if (own = tool_class && tool.try(:details, arguments)) then own
    elsif preview then preview.slice("to", "cc", "bcc", "subject", "attachments", "body").compact_blank
    else call_arguments.except(*(Tool::NOTE if notes_to_approver?))
    end
  end

  # What the agent wrote the person approving (Tool::NOTE), shown on the card
  # and never passed to the tool.
  def note_to_approver = (call_arguments[Tool::NOTE].presence if notes_to_approver?)

  # The arguments the tool acts on: all but the note to the approver, taken
  # out here, the one way into a tool's call, so no tool can send it.
  def action_arguments
    return arguments unless notes_to_approver?
    tool_name == "use_tool" ? arguments.merge("arguments" => call_arguments.except(Tool::NOTE)) : arguments.except(Tool::NOTE)
  end

  # A call's own approval policy may depend on its agent; connector metadata
  # still supplies the title and note when the call has none of its own.
  def approval_title = tool.try(:approval_title, arguments) || tool_class.try(:approval_title, arguments)
  def approval_note = tool.try(:approval_note, arguments) || tool_class.try(:approval_note, arguments)

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
    when :payment then "Approve a payment in Link?"
    else "Allow #{tool_name == "use_tool" ? ApplicationController.helpers.tool_label("use_tool", arguments) : tool_name.humanize(capitalize: false)}?"
    end
  end

  def answerable? = awaiting_person? && expires_at&.future?

  def finished? = succeeded? || failed? || denied?

  # A question asked without waiting (Tool::AskPerson#later?): its call ended
  # at once, naming it, and its card is Rails' to finish, as a handed-back
  # approval's is. Its answer, or its end, is told to the agent (#report).
  def asked_later? = asks == :question && handed_back_at.present?

  # An approval card raised by a call of the agent's own, or of a script it
  # ran: the one kind of approval an agent may take back itself
  # (Tool::WithdrawCard). Never a helper's, whose calls are the helper's, and
  # never a card that asks :sign_in or :payment, which are settled where they
  # are answered: the person's own form, and Link's app. A card that asks for
  # approval is this form's, however it reads: ask_outside_for_sign_in asks
  # :approval, and issues its link only once allowed, so taking it back leaves
  # nothing behind.
  def own_approval_card? = asks == :approval && self.class.agents_own?(call_id)

  # A card the agent that raised it may close unanswered: still open, and one
  # of those two kinds. Read inside the lock a decision takes (#settle_person),
  # so a withdrawal and an approval racing cannot both win.
  def withdrawable? = answerable? && (asked_later? || own_approval_card?)

  # The agent settled it itself (Tool::WithdrawQuestion, Tool::WithdrawCard):
  # the card closes unanswered and can no longer be allowed or answered, and
  # nothing is told back to the agent that withdrew it.
  def withdraw!
    with_lock { withdrawable? ? fail_with(asked_later? ? WITHDRAWN : WITHDRAWN_CARD) : raise(Conflict) }
    # A card never handed back still holds a wait in the sidecar: its call is
    # told at once, as a person's answer tells it. A handed-back one has none.
    InvocationWakeJob.perform_later(self) unless handed_back_at
  end

  def withdrawn? = failed? && error.in?([ WITHDRAWN, WITHDRAWN_CARD ])

  # A question asked without waiting that closed unanswered, withdrawn or
  # expired. It is stored as failed so it can't be answered, but nothing went
  # wrong: the agent carried on, and its line reads as a finished step.
  def closed_unanswered? = failed? && asked_later?

  # What the opened-up line calls its error text: a question that closed
  # unanswered says how, so nothing reads as gone wrong.
  def error_label
    if withdrawn? then "Withdrawn"
    elsif closed_unanswered? then "Expired"
    else "Error"
    end
  end

  # Whether the agent need not wait on this card: an approval of a call of
  # its own, or of a script it ran (not a helper's: a helper's result is the
  # helper's, and its messages its own), whose result is all it reads.
  # A sign-in to fill, a payment or a file to save needs the sidecar after
  # it runs, and a question's answer is what the agent waits for, so those
  # hold the agent's step until the person answers, as before.
  def hands_back?
    asks == :approval && self.class.agents_own?(call_id) && !called.try(:fills?) && !called.try(:pays?) &&
      !called.try(:saves_file?) && mcp_file_tool.nil?
  end

  # Tells the agent how a handed-back call ended, once (InvocationReportJob):
  # a steer, read at its next step, or the start of a turn if it is idle.
  def report
    return report_question if asked_later?
    conversation.receive(from: "the card you stopped waiting on", via: "Approval", request_id: "invocation:#{id}", when_busy: "steer",
      source: { invocation_id: id }) do
      called = "#{tool_name} #{arguments.to_json}"
      body = case state
      when "succeeded" then "#{approval&.decided_by || 'The person'} allowed #{called}, and it ran once. Its result:\n\n#{result.is_a?(String) ? result : result.to_json}"
      when "denied" then "#{approval&.decided_by || 'The person'} declined #{called}. It did not run."
      else "#{called} did not run to the end: #{error}"
      end
      [ body, "It answers a call you made earlier, which stopped waiting on its card so you could read your messages. Tell the person what matters." ]
    end
  end

  # Marked with the question's id, as the agent was given it: the agent
  # decides whether the answer still matters. Steered, as a handed-back
  # approval's is, and from no person: a question is no approval, so its
  # answer is read as words from the card, never an instruction.
  def report_question
    conversation.receive(from: "your question #{id}", via: "Question", request_id: "invocation:#{id}", when_busy: "steer",
      source: { invocation_id: id }) do
      asked = "your question #{id}, #{arguments["question"].to_json}"
      if succeeded?
        [ "#{answer&.decided_by || 'The person'} answered #{asked}: #{result.to_json}",
          "It answers a question you asked without waiting. Decide whether it still matters; if you settled it meanwhile, carry on without it." ]
      elsif expires_at&.past?
        [ "#{asked.upcase_first}, expired: nobody answered in time. Its card is closed and it can no longer be answered.",
          "Ask again only if it still matters." ]
      else
        [ "#{asked.upcase_first}, closed unanswered: #{error}", "Ask again only if it still matters." ]
      end
    end
  end

  # A claimed outside call, made by InvocationCallJob with no transaction
  # open. Its result is recorded only if the call is still this one's to
  # finish; one lost past RUN_LIMIT has already failed.
  def call_outside
    return unless start
    raise Tool::Refusal, "#{tool_name} is no longer available." unless tool_class
    return if changed_since_approved?
    result = tool.call(**action_arguments.symbolize_keys)
    with_lock { update!(state: :succeeded, result: result) if running? }
  rescue Tool::Refusal => refusal
    log_failure(refusal.cause || refusal)
    with_lock { fail_with(refusal.message) if running? }
  rescue => error
    # Any other error fails the call too, at once, saying it may have
    # happened, rather than leaving it running until RUN_LIMIT.
    log_failure(error)
    Rails.error.report(error, context: { invocation_id: id, tool: tool_name })
    with_lock { fail_with("#{tool_name} failed (#{error.class}). It may or may not have happened; check before trying again.") if running? }
  end

  # The sidecar's name for the wait this call holds (agent/extensions.mjs).
  def wait_key = "#{task_id}:#{call_id}"

  def tool_class = conversation.tool(tool_name)

  # The tool the call reaches: itself, or the one use_tool calls (Tool::UseTool),
  # whose answer the sidecar acts on as if it were called directly.
  def called = tool_class.is_a?(Tool::UseTool) ? tool_class.target(arguments["name"]) : tool_class

  # Its name and arguments as the tool it reaches gets them: through use_tool
  # (Tool::UseTool), the tool it names and the arguments it passes on.
  def call_name = tool_name == "use_tool" ? arguments["name"].to_s : tool_name
  def call_arguments = tool_name == "use_tool" ? arguments["arguments"].to_h : arguments

  # The files the sidecar read for this call (Tool.reads_files).
  def uploads = conversation.uploads.where(task_id: task_id, call_id: call_id)

  # The page element for this call, named by the model's call id so the
  # assistant message that made the call can hold it before this row exists.
  def self.dom_target(call_id) = "tool_call_#{Digest::SHA256.hexdigest(call_id.to_s).first(16)}"
  def dom_target = self.class.dom_target(call_id)

  # A call made inside another is named under it, `<parent>/<own>`: a code
  # mode script's calls (`<script>/c<n>`), a helper's (`<helper>/<call>`), a
  # script a helper ran (`<helper>/<script>/c<n>`). One rule for all three.
  def self.parent_call_id(call_id) = call_id.to_s.rpartition("/").first.presence

  # A call the agent made itself, or a code mode script of its own made
  # (`<script>/c<n>`, the name pi-durable's code mode gives it), not a
  # helper's. The sidecar asks to hand back only these; this is Rails' check.
  def self.agents_own?(call_id) = !parent_call_id(call_id) || call_id.to_s.match?(%r{\A[^/]+/c\d+\z})

  # The run a run_workflow call started (Tool::RunWorkflow), drawn on its line.
  def workflow_run = (conversation.workflow_runs.find_by(call_id: call_id) if tool_name == "run_workflow" && succeeded?)

  # The background helper that made this call, if one did (Helper).
  def helper = conversation.helpers.find_by(call_id: self.class.line_call_id(call_id))
  def parent_call_id = self.class.parent_call_id(call_id)

  # The line a nested call is listed in: the outermost, the call the agent's
  # reply made, which is always on the page. A line in between (a script a
  # helper ran) is live only and redrawn as it runs, so what is listed inside
  # it would be lost.
  def self.line_call_id(call_id) = (call_id.to_s.split("/").first if parent_call_id(call_id))

  def trace_status
    case state
    when "succeeded" then "done"
    # Withdrawn or closed unanswered: the step ended as it was meant to, so no error dot.
    when "failed" then withdrawn? || closed_unanswered? ? "done" : "error"
    when "denied" then "error"
    when "awaiting_person" then "pending"
    else "running"
    end
  end

  # The card in the thread shows where the call stands now; a payment's own changes ask too (PaymentRequest).
  # A card that starts or stops waiting moves the thread's attention, never its
  # run (Conversation::Activity): answering the last one shows whatever the
  # agent's run is, idle if it ended meanwhile. The line above the box follows,
  # and the list's row, whose line names the newest card, even while the
  # thread stays waiting.
  def show_progress
    show
    return unless awaiting_person? || state_before_last_save == "awaiting_person"
    redrawn = conversation.settle
    conversation.broadcast_needs_you
    conversation.broadcast_row if !redrawn && saved_change_to_state?
  end

  def show
    if (line = self.class.line_call_id(call_id))
      # Listed inside its line; appending an element already there replaces it.
      broadcast_append_to conversation, target: "#{self.class.dom_target(line)}_calls", partial: "invocations/invocation", locals: { invocation: self }
    else
      broadcast_replace_to conversation, target: dom_target, partial: "invocations/invocation", locals: { invocation: self }
    end
  end

  private
    def tool = @tool ||= tool_class.new(self)

    # Only a built-in that asks for approval declares the note; a connector's
    # own argument of the same name is its own.
    def notes_to_approver? = tool_class && called.try(:notes_to_approver?)

    # The connector's tool behind the call, made directly or through
    # use_tool, and of a Tool::Mcp::Group, the chosen account's.
    def mcp_tool
      found = tool_class
      found = found.target(arguments["name"]) if found.is_a?(Tool::UseTool)
      found = found.member(call_arguments) if found.is_a?(Tool::Mcp::Group)
      found if found.is_a?(Tool::Mcp)
    end

    # One of the connector's file tools (Tool::Mcp#finds_file?).
    def mcp_file_tool = mcp_tool&.then { it if it.finds_file?(call_arguments) }

    # The files a connector's answer carried, and its long answer
    # (Tool::Mcp::FoundFile, LongAnswer): each held here, or linked on the
    # connector's own address (McpServer::LinkedFile). And the files mail
    # brought or a person attached, on a row of their own (Conversation::Handover), all held here.
    def found_files
      return [] unless result.is_a?(Hash) && result["found_files"].is_a?(Array) && (Conversation::Handover.row?(self) || mcp_tool)
      result["found_files"].select { it.is_a?(Hash) && (it["held"].is_a?(Integer) || it["link"].is_a?(String)) }
    end

    def found_download(index)
      entry = result["found_files"][index] if index >= 0
      return unless found_files.include?(entry)
      entry.key?("held") ? held_download(entry["held"]) : McpServer::LinkedFile.new(mcp_tool.server).download(entry["link"])
    end

    # Streamed from storage to a Tempfile, never whole in memory.
    def held_download(place)
      held = held_files.attachments.order(:id).offset(place).first or return
      file = Tempfile.new("held-file", binmode: true)
      held.download { file.write(it) }
      whole = file.tap(&:flush).tap(&:rewind)
    ensure
      file&.close! unless whole
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
      # What the agent calls of what find_tools found becomes its own tool from the next message, only where
      # the person lets it (Agent#promotes_found_tools); calling it again keeps it.
      if agent.promotes_found_tools?
        called = tool_name == "use_tool" ? arguments["name"] : tool_name
        conversation.activate([ called ]) if tool_name == "use_tool" || conversation.activated_tools.include?(called)
      end
      return fail_with(tool.refusal) if tool.refusal
      return fail_with(tool.contact_refusal) if tool.contact_refusal
      return wait_on_person if asks && !(asks == :approval && agent.allows?(tool))
      perform
    end

    def perform
      return fail_with("#{tool_name} is no longer available.") unless tool_class && tool.permitted?
      return fail_with(tool.contact_refusal) if tool.contact_refusal
      return claim if tool_class.effect == :external
      update!(state: :succeeded, result: tool.call(**action_arguments.symbolize_keys))
    rescue Tool::Refusal, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => refusal
      fail_with(refusal.message)
    end

    # A question asked without waiting is handed back from the start: the
    # agent carries on, and Rails finishes the card (#asked_later?).
    def wait_on_person
      update!(state: :awaiting_person, expires_at: (tool.try(:expires_in) || WAIT).from_now, handed_back_at: (Time.current if tool.try(:later?)))
    end

    # A running call the sidecar asks about again. One claimed by code from
    # before claimed_at (#238) is judged as one already begun.
    def overdue
      if claimed_at && !started_at
        wait_for_job
      elsif (started_at || updated_at) < RUN_LIMIT.ago
        lost
      end
    end

    # Its job has not begun the call, so nothing has gone: behind a busy job
    # role it waits, and is queued again if its job is gone. Past QUEUE_LIMIT
    # it ends, saying it was never made.
    def wait_for_job
      return if claimed_at > RUN_LIMIT.ago
      if claimed_at < QUEUE_LIMIT.ago
        fail_with("#{tool_name}: #{NEVER_STARTED}")
      elsif !InvocationCallJob.queued?(self)
        Rails.logger.warn("Invocation #{id}: #{tool_name}'s job was gone before it began; queued again")
        @claimed = true
      end
    end

    def lost
      tool_class.try(:safe_to_repeat?) ? perform : fail_with("#{tool_name}: #{LOST}")
    end

    # A replay that arrives meanwhile is told to wait, rather than calling again.
    # The sidecar holds that wait as it holds a person's (CONTRACT.md).
    def claim
      now = Time.current
      update!(state: :running, claimed_at: now, started_at: nil, updated_at: now)
      @claimed = true
    end

    # The job begins the call, recorded before anything leaves, so a call
    # running past RUN_LIMIT is known to have perhaps happened. A job run
    # again (a worker that died mid-call) goes on as before, from the first
    # start; Dispatch keeps its sends from going twice. A job is queued again
    # only for a call never begun (#wait_for_job).
    def start
      with_lock do
        next false unless running?
        update!(started_at: Time.current) unless started_at
        true
      end
    end

    # One line whoever runs the install can read without the error tracker:
    # the error's class and the server's status, never the call's arguments
    # or anything read or written.
    def log_failure(error)
      status = error.try(:status)
      Rails.logger.warn("Invocation #{id}: #{tool_name} failed: #{error.class}#{" (HTTP #{status})" if status.is_a?(Integer)}")
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
