# Files Rails itself hands the agent's computer, not a tool: a received mail's
# (ReceivedMail::Files) and a person's from the thread (Conversation::Attachments).
# Each is held on a ledger row of its own (Invocation#hold_file) while the
# sidecar fetches it back by its place (POST /agent/files) and writes it under
# ~/files (agent/files.mjs), and is listed for the model with where it was
# saved or, plainly, why not. Nothing is cut for its size here; only a
# computer with no room refuses one.
#
# What was said is kept on the row, so the same files asked again (the same
# mail read twice, a send retried) are listed the same and not saved twice.
class Conversation::Handover
  # The rows that hold such files, by task: the only ones besides a
  # connector's whose found_files the sidecar may fetch (Invocation#found_files).
  TOOLS = { "email" => "received_email", "composer" => "attached_file" }.freeze

  def self.row?(invocation) = TOOLS[invocation.task_id] == invocation.tool_name

  # Someone else's words on one line: no line breaks or control characters.
  def self.plain(text) = text.to_s.gsub(/[[:cntrl:]\p{Cf}]+/, " ").squish.truncate(200)

  def initialize(conversation, task:, call_id:)
    @conversation, @task, @call_id = conversation, task, call_id
  end

  # One line for each file (anything with a name, type and bytes), in order.
  def lines(files)
    outcomes = @conversation.agent.saves_files? ? saved(files) : files.map { { "note" => "you have no computer here to save it on." } }
    files.zip(outcomes).map do |file, outcome|
      where = outcome["saved"] ? "saved at #{outcome["saved"]}#{"; its words are in #{outcome["full_text"]}" if outcome["full_text"]}" : "not saved: #{outcome["note"]}"
      "- #{file.name} (#{file.type}, #{ActiveSupport::NumberHelper.number_to_human_size(file.bytes.bytesize)}): #{where}"
    end
  end

  private
    def saved(files)
      row = @conversation.invocations.find_by(task_id: @task, call_id: @call_id)
      return row.result["found_files"] if row&.result.is_a?(Hash) && row.result["found_files"].to_a.all? { it.key?("saved") }
      @conversation.admit!
      row ||= @conversation.invocations.create_or_find_by!(task_id: @task, call_id: @call_id) do
        it.tool_name = TOOLS.fetch(@task)
        it.digest = Invocation.digest_for(@conversation, task_id: @task, call_id: @call_id, tool: it.tool_name, arguments: {})
        it.state = "succeeded"
      end
      row.held_files.purge
      held = files.map { { "name" => it.name, "type" => it.type, "size" => it.bytes.bytesize,
        "held" => row.hold_file(io: StringIO.new(it.bytes), filename: it.name, content_type: it.type) } }
      row.update!(result: { "found_files" => held })
      outcome = save(row, held)
      row.update!(result: { "found_files" => held.zip(outcome).map { |file, said| file.merge(said) } })
      row.result["found_files"]
    end

    # What the sidecar said of each file, or why it could not be asked.
    def save(row, held)
      answer = DurableAssistants::PiDurable::Client.new.save_files(@conversation.access, @conversation.durable_id,
        computer: @conversation.agent.computer.descriptor, task_id: row.task_id, call_id: row.call_id, files: held).fetch("files")
      held.each_index.map { said(answer[it].to_h) }
    rescue DurableAssistants::PiDurable::Client::Error, KeyError => error
      Rails.logger.warn("#{@task.capitalize} files not saved for conversation #{@conversation.id}: #{error.class.name} #{error.try(:category)}")
      held.map { { "saved" => nil, "note" => unreachable(error.try(:category)) } }
    end

    def said(file)
      if file["saved"].is_a?(String) then file.slice("saved", "full_text")
      else { "saved" => nil, "note" => self.class.plain(file["note"].presence || "the computer did not say why.") }
      end
    end

    def unreachable(category)
      case category
      when "computer_held" then "your computer is held while it is rebuilt."
      when "computers_busy" then "too many computers are awake to wake yours just now."
      else "your computer could not be reached."
      end
    end
end
