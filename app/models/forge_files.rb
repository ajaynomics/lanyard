# The forge job owns the lifetime of a transfer. The private callbacks run in
# the web role, so both use Rails' existing storage volume, not the computer's
# disk or Active Storage's browser-reachable files.
class ForgeFiles
  class Invalid < StandardError; end
  class TooLarge < Invalid; end
  class Busy < Invalid; end

  MAX_BYTES = 50.megabytes
  CHUNK_BYTES = 256.kilobytes
  DEADLINE = 120
  ROOT = "/home/agent/.forge"
  Location = Data.define(:bytes, :sha256) do
    def path = "#{ForgeFiles::ROOT}/#{sha256}.bundle"
  end

  def initialize(invocation, client: DurableAssistants::PiDurable::Client.new)
    @invocation = invocation
    @client = client
  end

  def stage(io:, bytes:, sha256:)
    transfer(:stage, bytes, sha256) do |session|
      session.store(io) { Binding.check!(@invocation) }
      command(session)
      Location.new(bytes, sha256.dup.freeze)
    end
  end

  def take(bytes:, sha256:)
    transfer(:push, bytes, sha256) do |session|
      command(session)
      session.open { |file| yield file }
    end
  end

  private
    def transfer(mode, bytes, sha256)
      Binding.check!(@invocation)
      Session.start(@invocation, mode, bytes, sha256) { |session| yield session }
    rescue IOError, SystemCallError, DurableAssistants::PiDurable::Client::Error
      raise Invalid, "forge_file_transfer_failed", cause: nil
    end

    def command(session)
      Binding.check!(@invocation)
      conversation = @invocation.conversation
      reply = @client.forge_file(conversation.access, conversation.durable_id, task_id: @invocation.task_id,
        call_id: @invocation.call_id, digest: @invocation.digest, transfer: session.id, mode: session.mode,
        bytes: session.bytes, sha256: session.sha256)
      raise Invalid unless reply == { "transferred" => true }
      Binding.check!(@invocation)
    end
end
