# One explicit send, prepared once before the sidecar is reached. A lost
# response leaves the same envelope to retry, not instructions to send later.
class Conversation::Submission < ApplicationRecord
  class Refused < StandardError; end
  class Conflict < Refused
    def initialize = super("An earlier send with this ID has different words, pictures or source. Check the conversation before trying again.")
  end

  class TooLarge < Refused
    def initialize = super("This message and its required context are too long. Shorten the message or its saved prompt, then send again.")
  end

  LIMIT = 65_536

  belongs_to :conversation
  encrypts :payload
  # The person's files (Conversation::Attachments), kept for its message,
  # which takes them when the sidecar records it (Conversation#record_entry).
  has_many_attached :files
  attr_readonly :conversation_id, :request_id, :input_digest, :payload_digest, :definition_digest, :context
  validates :request_id, :input_digest, :payload_digest, :definition_digest, presence: true
  validate :envelope_is_immutable

  # author: who said it, kept on the sidecar's entry for it (agent/state.mjs's
  # MessageEntry): { userId: } for a person, { sender: } for a channel's sender.
  def self.prepare(conversation, content, request_id:, when_busy:, images: [], files: [], document_changes: true, by_person: true, source: nil, author: nil, &presentation)
    raise TooLarge if source.nil? && content.to_s.bytesize > LIMIT
    raise ArgumentError unless Conversation::BUSY_MODES.include?(when_busy)
    unless request_id.is_a?(String) && request_id.present? && Conversation.utf16_length(request_id) <= 1_024
      raise DurableAssistants::PiDurable::Client::Error.new(422, "invalid_request")
    end
    conversation.reload
    blocks, digests = pictures(images)
    attachments = Conversation::Attachments.new(conversation, files, request_id: request_id)
    access = conversation.access
    input = { text: content, images: digests, when_busy: when_busy, source: source,
      actor: access.actor_id, workspace: access.workspace_id, document_changes: document_changes, by_person: by_person }
    # A sender is in the source already, and the agent's own person is its actor:
    # only another person is added, so a send prepared before authors digests as it did.
    input[:author] = author[:userId] if author&.dig(:userId) && author[:userId] != access.actor_id
    input[:files] = attachments.digests if attachments.any?
    digest = Agent::Canonical.digest(input)
    if (prior = conversation.submissions.find_by(request_id: request_id))
      return prior.match!(digest)
    end

    # Expansions, file reads and diffs can be slow. Only publishing a complete
    # candidate takes the conversation lock; simultaneous prepares use its winner.
    candidate = conversation.submissions.new(request_id: request_id, input_digest: digest)
    candidate.prepare_payload(presentation ? presentation.call : content, blocks, when_busy, document_changes, by_person, outside: !source.nil?, author: author,
      attached: attachments.note)
    attachments.attach_to(candidate)
    conversation.with_lock do
      conversation.submissions.find_by(request_id: request_id)&.match!(digest) || candidate.tap(&:save!)
    end
  end

  def match!(digest)
    raise Conflict unless input_digest == digest
    self
  end

  class Paused < Refused
    def initialize = super("This agent is paused, and an old branch thread doesn't hold messages. Resume it, then send again.")
  end

  # Its agent is holding: it waits here, prepared, until Conversation#deliver_held
  # sends it; the job resuming it sends what comes meanwhile too. An old
  # branch thread doesn't hold (Conversation::Holding): a send there is refused
  # while its agent is paused, and may be sent again, under the same id, once resumed.
  def deliver
    raise Paused if conversation.parent_id && conversation.agent.reload.paused?
    return deliver! unless held?
    conversation.broadcast_held
    nil
  end

  # Sent now, held or not.
  def deliver!
    unless accepted_at
      conversation.admit!
      with_lock do
        raise Conversation::Mismatch if durable_id && durable_id != conversation.durable_id
        update!(durable_id: conversation.durable_id) unless durable_id
      end
      # No database transaction spans either sidecar request. A simultaneous
      # dispatch can only replay this exact body under the original ID.
      # The words go as first prepared; the agent's settings go as they are
      # now, so a late retry never puts back instructions or tools since changed.
      # The sidecar's own duplicate check does not count the definition.
      definition = conversation.definition
      response = begin
        dispatch(definition)
      rescue DurableAssistants::PiDurable::Client::Error => error
        # A sidecar from before lookup or helpers' models (mid-deploy, the roles
        # move one at a time) refuses a key it doesn't know, before it records
        # anything. The same words go again without them; use_tool still
        # reaches those tools, and helpers run on the agent's own model.
        raise unless error.category == "invalid_definition" && (definition.key?(:lookup) || definition.key?(:helperModels))
        definition = conversation.agent.definition(conversation.tools, helper_models: false)
        dispatch(definition)
      end unless accepted_at
      accept!(response, definition.fetch(:digest)) if response
    end
    acknowledge!
    # One the sidecar queued, or took while its agent holds, keeps its body,
    # to be held should the pause catch it (Conversation#hold_queued);
    # Conversation#refresh_status! lets it go.
    compact! unless receipt["status"] == "queued" || conversation.holding_since
    conversation.pull
    receipt
  rescue DurableAssistants::PiDurable::Client::Error => error
    # Status and category only: never what it said.
    Rails.logger.warn "Send #{id} to conversation #{conversation_id} failed: #{error.status} #{error.category || "no category"}"
    raise Conflict if error.category == "request_conflict"
    # Refused before the sidecar admitted it: the same id may carry words only.
    destroy! if error.category == "images_unsupported" && !accepted_at
    raise Conversation::ImagesRefused, "#{conversation.agent}'s model can't look at pictures. Send words only, or choose another model in its settings." if error.category == "images_unsupported"
    Rails.logger.error "Agent #{conversation.agent_id} exceeded the declared tool limit" if error.category == "tool_limit"
    raise
  end

  def prepare_payload(text, images, when_busy, document_changes, by_person, outside: false, author: nil, attached: "")
    agent = conversation.agent
    summary = summary_key
    definition = conversation.definition
    expanded = agent.expand(text)
    documents = document_changes ? agent.documents.changed_since_seen.filter_map(&:context) : []
    helpers = conversation.helpers.untold.to_a
    runs = conversation.workflow_runs.untold.to_a
    date = conversation.today
    note = conversation.date_note(on: date)
    notices = +""
    notices << Helper.cancellations_for_agent(helpers) if helpers.any?
    notices << Workflow::Run.cancellations_for_agent(runs) if runs.any?
    notices << note if note
    # A message from outside is cut to the room the notices leave, saying so:
    # nobody is there to shorten it, and a refusal would come back every retry.
    expanded = Conversation.within_words_limit(expanded, LIMIT - Conversation.utf16_length(notices)) if outside
    expanded += attached
    room = LIMIT - Conversation.utf16_length(expanded) - Conversation.utf16_length(notices)
    raise TooLarge if room.negative?
    changes = documents.any? ? Document.changes_for_agent(documents, room: room) : ""
    text = "#{expanded}#{changes}#{notices}"
    raise TooLarge if Conversation.utf16_length(text) > LIMIT
    transmitted = images.empty? ? text : [ ({ type: "text", text: text } if text.present?), *images ].compact
    access = conversation.access
    # The person's own words, not a channel's: the sidecar puts his steer ahead of others'.
    self.payload = JSON.generate({ requestId: request_id, content: transmitted, whenBusy: when_busy, definition: definition,
      actorId: access.actor_id, workspaceId: access.workspace_id, fromPerson: (true unless outside), author: author }.compact)
    self.payload_digest = Digest::SHA256.hexdigest(payload)
    self.definition_digest = definition.fetch(:digest)
    self.context = { "documents" => documents.map { it.slice("document_id", "from_version_id", "version_id") },
      "helpers" => helpers.map(&:id), "runs" => runs.map(&:id), "date" => (date.iso8601 if note),
      "summary" => summary, "time_zone" => agent.time_zone,
      "document_changes" => document_changes, "by_person" => by_person }
  end

  # Prepared since its agent was paused, and unsent: Conversation#held, asked
  # afresh, since the agent may have been paused or resumed since it was loaded.
  def held?
    since = conversation.holding_since
    !accepted_at && since.present? && created_at >= since
  end

  # A copy of this envelope, unsent, for one the sidecar gave back as its agent
  # was paused, in the mode it waited in, or took in a run the pause refused.
  # Its own id: the sidecar never takes in a submission again under the id it
  # came with. Dated at the pause: sent before it, it goes before what was held.
  def held_copy(when_busy: nil)
    copy_id = "#{request_id}:held"
    conversation.submissions.create_or_find_by!(request_id: copy_id) do |copy|
      copy.created_at = conversation.holding_since
      copy.payload = JSON.generate(JSON.parse(payload).merge({ "requestId" => copy_id, "whenBusy" => when_busy }.compact))
      copy.assign_attributes(input_digest: input_digest, payload_digest: Digest::SHA256.hexdigest(copy.payload),
        definition_digest: definition_digest, context: context)
    end
  end

  # What a held message says, for the list of those waiting: as the sidecar's own list has it.
  def shown
    content = JSON.parse(payload)["content"]
    blocks = content.is_a?(String) ? [ { "type" => "text", "text" => content } ] : Array(content)
    { "id" => id.to_s, "text" => blocks.select { it["type"] == "text" }.sum("") { it["text"].to_s },
      "pictures" => blocks.count { it["type"] == "image" } }
  end

  # The person drops a held message: it never reaches the agent. A Concourse
  # task is answered, once, since its sender waits on one: every message of
  # that task held goes with it, as a task rejected can't be answered after.
  # Nobody is written to by mail or in Campfire. Logged by channel, never by
  # what it said. Only while paused, under the agent's lock: once a resume
  # has begun, it may be on its way, and false says it was not dropped.
  def drop
    task = conversation.peer_tasks.sent_as(request_id)
    agent = conversation.agent
    dropped = agent.with_lock { (task ? conversation.held.select { task.sent_as?(it.request_id) } : [ self ]).each(&:destroy!) if agent.paused? }
    return false unless dropped
    task&.answer("TASK_STATE_REJECTED", "Dropped by the owner while the agent was paused.")
    Rails.logger.info "Held #{request_id[/\A(email|campfire|concourse|routine|helper|workflow):/, 1] || "person's"} message dropped from conversation #{conversation_id}"
    true
  end

  def compact!
    with_lock do
      update!(payload: nil, compacted_at: Time.current) if acknowledged_at && payload
    end
  end

  # The receipt and the context acknowledgment have separate durable points.
  # A crash between them resumes here, without admitting another message.
  def acknowledge!
    with_lock do
      return if acknowledged_at
      raise Conversation::Mismatch unless accepted_at && receipt.present?
      conversation.reload
      acknowledge_documents
      conversation.helpers.where(id: context.fetch("helpers"), told_at: nil).update_all(told_at: Time.current)
      conversation.workflow_runs.where(id: context.fetch("runs"), told_at: nil).update_all(told_at: Time.current)
      acknowledge_date
      conversation.update!(error_told_at: nil) if context["document_changes"]
      conversation.agent.workspace.campfire_rooms.person_wrote! if context["by_person"]
      later = conversation.submissions.where.not(accepted_at: nil).where("id > ?", id).exists?
      conversation.unarchive
      # Only the request that was first accepted starts the run. One retried
      # after a crash before this point may find the run long finished, and a
      # cached acceptance is no new message to revive it.
      conversation.settle(execution: "running") if @accepted_now && !later && !receipt["status"].in?(%w[ done cancelled error unanswered ])
      update!(acknowledged_at: Time.current)
    end
  end

  private
    def client = DurableAssistants::PiDurable::Client.new

    def with_definition(definition) = JSON.generate(JSON.parse(payload).merge("definition" => definition))

    # Sent, and no answer: a sidecar slow mid-turn may have taken it after the
    # client gave up. Asked once more under the same id, it answers from its
    # record (agent/runtime.mjs submit; pi-durable admits a request id once),
    # so an accepted send is reported delivered, never delivered twice.
    def dispatch(definition)
      client.submit_prepared(conversation.access, durable_id, body: with_definition(definition))
    rescue DurableAssistants::PiDurable::Client::Error => error
      raise unless error.unanswered?
      Rails.logger.warn "Send #{id} to conversation #{conversation_id} got no answer; asking again under the same id"
      client.submit_prepared(conversation.access, durable_id, body: with_definition(definition))
    end

    def accept!(response, sent_definition)
      raise DurableAssistants::PiDurable::Client::Error.new(502) unless response.is_a?(Hash) && Agent::Access.valid_id?(response["id"].to_s)
      with_lock do
        next if accepted_at
        update!(receipt: response, accepted_at: Time.current)
        @accepted_now = true
      end
      conversation.update!(definition_digest: sent_definition)
    end

    def acknowledge_documents
      context.fetch("documents").each do |reference|
        document = conversation.agent.documents.find_by(id: reference.fetch("document_id"))
        version = document&.versions&.find_by(id: reference.fetch("version_id"))
        document.seen!(version: version) if version
      end
    end

    def acknowledge_date
      date = context["date"]&.to_date
      return unless date
      return unless context["summary"] == summary_key && context["time_zone"] == conversation.agent.time_zone
      conversation.update!(dated_on: date) if conversation.dated_on.nil? || conversation.dated_on < date
    end

    def summary_key
      conversation.messages.where(role: "summary").order(entry_id: :desc, id: :desc).pick(:entry_key)
    end

    def envelope_is_immutable
      errors.add(:payload, "cannot change after preparation") if persisted? && will_save_change_to_payload? && payload.present?
      errors.add(:receipt, "cannot change after acceptance") if will_save_change_to_receipt? && receipt_in_database.present?
      errors.add(:durable_id, "cannot change after dispatch") if will_save_change_to_durable_id? && durable_id_in_database.present?
    end

    class << self
      private
        def pictures(files)
          raise Conversation::ImagesRefused, "Attach up to #{Conversation::IMAGES_PER_MESSAGE} pictures to one message." if files.size > Conversation::IMAGES_PER_MESSAGE
          pairs = files.map { picture(it) }
          [ pairs.map(&:first), pairs.map(&:last) ]
        end

        def picture(file)
          file.rewind
          bytes = file.read(Conversation::IMAGE_BYTES + 1)
          raise Conversation::ImagesRefused, "Each picture must be 5 MB or smaller." if bytes.bytesize > Conversation::IMAGE_BYTES
          type = Marcel::MimeType.for(StringIO.new(bytes))
          raise Conversation::ImagesRefused, "Only PNG, JPEG, WebP and GIF pictures can be sent." unless Conversation::IMAGE_TYPES.key?(type)
          [ { type: "image", data: Base64.strict_encode64(bytes), mimeType: type }, { digest: Digest::SHA256.hexdigest(bytes), type: type } ]
        ensure
          file.rewind
        end
    end
end
