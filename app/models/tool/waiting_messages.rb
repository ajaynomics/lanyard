# The agent's out-of-band inbox (#85): what others sent (Concourse mail,
# email, texts, Campfire, Telegram) waits for it to finish its turn, unless
# it can't wait (Conversation::Urgency). The sidecar tells the agent at its next step that
# one is waiting; this lists who wrote each and how it starts, and takes some
# or all in sooner: each becomes a steer, read after the step this call is
# in, in the order they came. The person's own waiting words are not the
# agent's to take; they come in as the person chose. Looked up, not carried
# (Tool::Catalog::ALWAYS), so it adds nothing to the tools an agent declares.
class Tool::WaitingMessages < Tool
  description "See the messages from others waiting in your inbox for you to finish (Concourse mail, email, texts, Campfire, Telegram): who sent each and " \
    "how it starts. With take, read some or all of them now instead: they come in after this step. Untaken, they come in when you finish."
  argument :take, :array, required: false, max_items: 32, items: { type: "string", pattern: "^(all|[0-9]{1,18})$" },
    description: "Ids from the list to read now, or [\"all\"]."

  # It asks the sidecar, which can take seconds mid-turn: run as an outside
  # call, off the request and outside SQLite's one write lock.
  effect :external

  STARTS = 120

  def call(take: nil)
    waiting = conversation.waiting_from_others
    return { waiting: waiting.map { listed(*it) } } if take.nil?

    ids = take.include?("all") ? waiting.map { it.first["id"] } : take
    taken, gone = ids.partition { |id| waiting.any? { it.first["id"] == id } && conversation.change_queued(id, when_busy: "steer") }
    { taken: taken, not_waiting: gone.presence,
      note: (taken.any? ? "They come in after this step, in the order they came." : "Nothing taken: none of those is waiting.") }.compact
  end

  private
    def listed(item, incoming)
      { id: item["id"], channel: incoming.channel, from: incoming.sender, untrusted: !incoming.trusted,
        starts: incoming.body.to_s.strip.lines.first.to_s.strip.truncate(STARTS), pictures: item["pictures"].nonzero? }.compact
    end
end
