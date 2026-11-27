# One message of Rails' copy of a conversation (see Conversation#sync!).
# Appended once per sidecar entry, in order, and shown as it arrives.
class Message < ApplicationRecord
  include PromptCache

  SHOWN = %w[ user assistant toolResult summary ].freeze
  # How the sidecar writes a reply's tool call into its words (entryView).
  TOOL_MARKER = /\[tool: [\w-]+\]/

  # The list sorts by the last message, so a status change does not reorder it.
  belongs_to :conversation, touch: :last_message_at
  # Who said it, as the sidecar's entry keeps it (agent/state.mjs's MessageEntry):
  # a person, or a channel's sender. A message from before (no request_id) has
  # neither, and is read from its words.
  belongs_to :author, class_name: "User", optional: true
  has_many_attached :images
  # Other files the person sent with it (Conversation::Attachments), in their original names.
  has_many_attached :files

  scope :shown, -> { where(role: SHOWN).order(:entry_id, :id) }
  # Finished replies (answer?), in SQL.
  # A peer's message over Concourse (Conversation.received).
  scope :concourse_mail, -> { where(role: "user").where("content LIKE ?", "[Concourse mail from %") }
  scope :answers, -> { where(role: "assistant").where("json_array_length(messages.tool_calls) = 0") }

  # A helper the agent started in the background works from the call's result, before it first reports.
  after_create_commit :helper_started, if: -> { role == "toolResult" && tool_name == "subagent" && !error }
  after_create_commit :broadcast_appended, if: :shown?
  # The lists' rows show the newest words (Conversation.with_preview), wherever the thread is open or not.
  after_create_commit -> { conversation.heard(self) }, if: -> { role.in?(%w[ user assistant ]) && content.to_s.gsub(TOOL_MARKER, "").strip.present? }

  # Markdown as the words it shows, on one line: a reply's opening for a notice.
  def self.plain_text(markdown)
    Nokogiri::HTML5.fragment(Commonmarker.to_html(markdown.to_s)).text.squish
  end

  # A summary takes the thread's date with what it summarizes: the next message tells it again.
  after_create -> { conversation.update!(dated_on: nil) }, if: -> { role == "summary" }

  # The thread's date (Conversation#date_note) is the model's alone: no view, copy or edit shows it.
  def content = self.class.without_notices(super)
  def self.without_notices(text) = text&.sub(Conversation::DATE_NOTE, "")&.sub(WORKFLOWS_CANCELLED, "")&.sub(HELPERS_CANCELLED, "")

  def shown? = SHOWN.include?(role)
  def from_person? = role == "user" && (spoken? ? author_id.present? : !incoming)

  # Who said an entry's message, as Rails' copy keeps it.
  def self.speaker(entry)
    author = entry["author"].is_a?(Hash) ? entry["author"] : {}
    { request_id: (entry["requestId"] if entry["requestId"].is_a?(String)),
      author_id: (Integer(author["userId"], exception: false) if author["userId"].is_a?(String)),
      sender: (author["sender"] if author["sender"].is_a?(String)) }
  end

  # Concourse names the task after its sender; a routine has no one behind it.
  def self.sender_named(via, from)
    case via
    when "Concourse mail" then from.split(", task ").first
    when "Routine", "Task alarm", "Helper", "Workflow", "Approval", "Question" then nil
    else from
    end
  end

  # A summary's own words, without the frame the model reads it in.
  def summary_text = content[%r{<summary>\n?(.*?)\n?</summary>}m, 1] || content

  # The person's edits to the canvas that went with their message
  # (Document.changes_for_agent): for the agent, not for the bubble.
  # Helpers the person cancelled, told with the next message
  # (Helper.cancellations_for_agent): for the agent, not for the bubble.
  # Workflows the person cancelled (Workflow::Run.cancellations_for_agent), likewise.
  WORKFLOWS_CANCELLED = %r{\n\n<workflows_cancelled>\nThe person cancelled the workflow.*\n</workflows_cancelled>\z}m
  HELPERS_CANCELLED = %r{\n\n<helpers_cancelled>\nThe person cancelled the helper.*\n</helpers_cancelled>\z}m
  DOCUMENT_CHANGES = %r{\n\n<document_changes>\nThe person changed these documents in the canvas.*\n</document_changes>\z}m
  # The files the person attached, with where each was saved
  # (Conversation::Attachments#note): for the agent; the bubble shows them as files.
  ATTACHED_FILES = %r{\n\n<attached_files>\n#{Conversation::Attachments::HEADING}\n.*\n</attached_files>\z}m

  # The words as the person sent them, without their canvas edits.
  # A message that came in through a channel (Conversation#receive), read
  # back from the note before it: who sent it, through what, and its words.
  # The model still reads the note; people see the message as its sender's.
  Incoming = Data.define(:sender, :channel, :body, :trusted) do
    # A peer agent, a helper and Campfire's bots (agents among them) write Markdown; an email or a text is plain words.
    def markdown? = channel.in?(%w[ Concourse Campfire Helper Workflow ])
  end
  CHANNELS = { "Concourse mail" => "Concourse", "Email" => "Email", "Text" => "Text", "Campfire" => "Campfire", "Telegram" => "Telegram", "Routine" => "Routine", "Task alarm" => "Task alarm", "Phone call" => "Phone call", "Helper" => "Helper", "Workflow" => "Workflow", "Approval" => "Approval", "Question" => "Question", Workspace::AgentSetup::HANDOFF_CHANNEL => "Manager" }.freeze
  # Only a routine, which the person set up, comes in trusted.
  RECEIVED_TRUSTED = /\A\[(Routine) from ([^\n]+?)\. [^\n]*\]\n\n(.*)\z/m
  RECEIVED_UNTRUSTED = /\A\[(#{CHANNELS.keys.map { Regexp.escape(it) }.join("|")}) from ([^\n]+)\.#{Regexp.escape(Conversation::UNTRUSTED)} [^\n]*\]\n\n(.*)\z/m

  def incoming
    return unless role == "user" && !(spoken? && author_id)
    if (match = content.to_s.match(RECEIVED_UNTRUSTED))
      via, from, body = match.captures
      Incoming.new(sender: sender_of(via, from), channel: CHANNELS[via], body: body, trusted: false)
    elsif (match = content.to_s.match(RECEIVED_TRUSTED)) && !match[0].include?(Conversation::UNTRUSTED)
      via, from, body = match.captures
      Incoming.new(sender: sender_of(via, from), channel: CHANNELS[via], body: body, trusted: true)
    end
  end

  def said = from_person? ? content.to_s.sub(DOCUMENT_CHANGES, "").sub(ATTACHED_FILES, "") : content.to_s
  def document_changes? = from_person? && content.to_s.match?(DOCUMENT_CHANGES)

  # pi's skill block (Skill#invocation), read back the way its
  # parseSkillBlock does: the skill's name and what the person added.
  SKILL_BLOCK = %r{\A<skill name="([^"]+)" location="([^"]+)">\n(.*?)\n</skill>(?:\n\n(.+))?\z}m

  def skill_name = (skill_match[1] if from_person? && skill_match)
  def skill_arguments = skill_match&.[](4)&.strip.presence

  # The words as the person typed them, to recall into the composer.
  def typed
    skill_name ? [ "/skill:#{skill_name}", skill_arguments ].compact.join(" ") : said
  end


  # A finished reply, not one that called tools whose results come after it.
  def answer? = role == "assistant" && tool_calls.empty?

  # The ledger row behind a tool result, when the tool was one of the agent's.
  def invocation
    conversation.invocations.find_by(call_id: tool_call_id) if tool_call_id
  end

  # The call, as the reply that made it holds it, whose result this is.
  def placed_call
    return unless role == "toolResult" && tool_call_id
    reply = conversation.messages.where(role: "assistant")
      .where("EXISTS (SELECT 1 FROM json_each(messages.tool_calls) WHERE json_extract(json_each.value, '$.id') = ?)", tool_call_id).last
    reply&.tool_calls&.find { it["id"] == tool_call_id }
  end

  private
    def helper_started
      call = placed_call
      return unless call&.dig("arguments", "background") == true && (task = call.dig("arguments", "task")).present?
      Helper.started(conversation, call_id: tool_call_id, task: task)
    end

    def skill_match = (@skill_match ||= [ said.match(SKILL_BLOCK) ]).first

    def broadcast_appended
      # A tool result shows in its call's place: a ledger row shows its own, and
      # a sidecar tool's (a computer's bash, a code mode script) fills in its
      # call's line, in the reply that made it. Only a result whose call is not
      # on the page is appended on its own.
      if role == "toolResult" && (invocation || (call = placed_call))
        fill_in(call) if call && !invocation
        return
      end

      broadcast_append_to conversation, target: "messages", partial: "messages/message", locals: { message: self }
      # A call reaches Rails as soon as the reply that made it commits, often
      # before the reply is pulled here, so its card may have gone out while
      # the reply was not on the page, or just after the reply was drawn
      # without it. Sent again after the reply, it is never missed.
      conversation.invocations.where(call_id: tool_calls.pluck("id")).each(&:show) if tool_calls.any?
      # The reply is on the page now: its live copy goes in the same breath, or
      # it shows twice. A reply that calls a tool has more coming.
      conversation.clear_live(working: tool_calls.any?) if role == "assistant"
      broadcast_remove_to conversation, target: ActionView::RecordIdentifier.dom_id(conversation, :empty) if from_person?
    end

    def fill_in(call)
      # Above any frame sent before it, so a late frame cannot bring the live output back.
      Turbo::StreamsChannel.broadcast_replace_to conversation, target: Invocation.dom_target(call["id"]), attributes: { method: :morph },
        partial: "messages/tool_call", locals: { call: call, result: self, invocations: conversation.invocations.index_by(&:call_id),
          seq: (Time.current.to_f * 1000).to_i }
    end

    # Kept with the message when it came; read from its words before that.
    def sender_of(via, from) = spoken? ? sender : self.class.sender_named(via, from)

    def spoken? = request_id.present?
end
