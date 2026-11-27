# The call ledger already binds the words. Keep the resolved peer and
# network alongside them so a card can't clear a different route later.
module Tool::ConcourseDestination
  def always? = !reviewed_destination && super

  def details(arguments)
    arguments.merge(reviewed_destination.slice("to", "network")) if reviewed_destination
  end

  private
    def review_destination(channel, peer, task)
      invocation.preview = { "concourse_destination" => destination(channel, peer, task) }
    end

    def verify_destination(channel, peer, task)
      return unless reviewed_destination && reviewed_destination != destination(channel, peer, task)
      raise Tool::Refusal, "The Concourse recipient or network changed after review. Nothing was sent."
    end

    def reviewed_destination = invocation.preview&.dig("concourse_destination")

    def destination(channel, peer, task)
      { "to" => peer, "network" => channel.organization, "identity" => channel.id, "sender" => channel.handle,
        "task" => task&.id, "context" => task&.context_id }
    end
end
