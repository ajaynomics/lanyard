# One message of Rails' copy of a conversation (see Conversation#sync!).
# Appended once per sidecar entry, in order, and shown as it arrives.
class Message < ApplicationRecord
  include PromptCache

  SHOWN = %w[ user assistant toolResult summary ].freeze
  # How the sidecar writes a reply's tool call into its words (entryView).
  TOOL_MARKER = /\[tool: [\w-]+\]/

  # The list sorts by the last message, so a status change does not reorder it.
  belongs_to :conversation, touch: :last_message_at
  has_many_attached :images

  scope :shown, -> { where(role: SHOWN).order(:entry_id, :id) }
  # Finished replies (answer?), in SQL.
  scope :answers, -> { where(role: "assistant").where("json_array_length(messages.tool_calls) = 0") }

  after_create_commit :broadcast_appended, if: :shown?
  # The lists' rows show the newest words (Conversation.with_preview), wherever the thread is open or not.
  after_create_commit :broadcast_preview, if: -> { role.in?(%w[ user assistant ]) && content.to_s.gsub(TOOL_MARKER, "").strip.present? }

  # Markdown as the words it shows, on one line: a reply's opening for a notice.
  def self.plain_text(markdown)
    Nokogiri::HTML5.fragment(Commonmarker.to_html(markdown.to_s)).text.squish
  end

  def shown? = SHOWN.include?(role)
  def from_person? = role == "user" && !incoming

  # A summary's own words, without the frame the model reads it in.
  def summary_text = content[%r{<summary>\n?(.*?)\n?</summary>}m, 1] || content

  # The person's edits to the canvas that went with their message
  # (Document.changes_for_agent): for the agent, not for the bubble.
  DOCUMENT_CHANGES = %r{\n\n<document_changes>\nThe person changed these documents in the canvas.*\n</document_changes>\z}m

  # The words as the person sent them, without their canvas edits.
  # A message that came in through a channel (Conversation#receive), read
  # back from the note before it: who sent it, through what, and its words.
  # The model still reads the note; people see the message as its sender's.
  Incoming = Data.define(:sender, :channel, :body, :trusted)
  CHANNELS = { "Concourse mail" => "Concourse", "Email" => "Email", "Campfire" => "Campfire", "Routine" => "Routine" }.freeze
  # Only a routine, which the person set up, comes in trusted.
  RECEIVED_TRUSTED = /\A\[(Routine) from ([^\n]+?)\. [^\n]*\]\n\n(.*)\z/m
  RECEIVED_UNTRUSTED = /\A\[(#{CHANNELS.keys.map { Regexp.escape(it) }.join("|")}) from ([^\n]+)\.#{Regexp.escape(Conversation::UNTRUSTED)} [^\n]*\]\n\n(.*)\z/m

  def incoming
    return unless role == "user"
    if (match = content.to_s.match(RECEIVED_UNTRUSTED))
      via, from, body = match.captures
      Incoming.new(sender: sender_named(via, from), channel: CHANNELS[via], body: body, trusted: false)
    elsif (match = content.to_s.match(RECEIVED_TRUSTED)) && !match[0].include?(Conversation::UNTRUSTED)
      via, from, body = match.captures
      Incoming.new(sender: sender_named(via, from), channel: CHANNELS[via], body: body, trusted: true)
    end
  end

  def said = from_person? ? content.to_s.sub(DOCUMENT_CHANGES, "") : content.to_s
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
      # The reply is on the page now: its live copy goes in the same breath, or
      # it shows twice. A reply that calls a tool has more coming.
      conversation.clear_live(working: tool_calls.any?) if role == "assistant"
      broadcast_remove_to conversation, target: ActionView::RecordIdentifier.dom_id(conversation, :empty) if from_person?
    end

    def broadcast_preview
      broadcast_update_to [ conversation.user, :conversations ], target: ActionView::RecordIdentifier.dom_id(conversation, :preview),
        html: ERB::Util.html_escape(ApplicationController.helpers.preview_of(content))
    end

    def fill_in(call)
      # Above any frame sent before it, so a late frame cannot bring the live output back.
      Turbo::StreamsChannel.broadcast_replace_to conversation, target: Invocation.dom_target(call["id"]), attributes: { method: :morph },
        partial: "messages/tool_call", locals: { call: call, result: self, invocations: conversation.invocations.index_by(&:call_id),
          seq: (Time.current.to_f * 1000).to_i }
    end

    # Concourse names the task after its sender; a routine has no one behind it.
    def sender_named(via, from)
      case via
      when "Concourse mail" then from.split(", task ").first
      when "Routine" then nil
      else from
      end
    end
end
