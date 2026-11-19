# How one of a person's workspaces stands, for Workspaces › Overview: its
# agents, the cards waiting on someone, what went wrong lately and the
# Campfire rooms held for spinning (Workspace::CampfireRoom). Read from
# what is stored, never a live sidecar or Campfire call: a page across every
# workspace can't wait on one slow service per workspace.
class Workspace::Health
  # A card unanswered this long is stuck: whoever it waits on has likely missed
  # it. So is one that expires sooner than that, however new: it is about to
  # fail unanswered.
  STUCK_AFTER = 1.hour
  # A call that failed longer ago than this was seen, or moved past.
  RECENT = 1.day

  attr_reader :workspace, :agents, :cards, :failed_calls

  # One for each workspace the person is in, their own first, from one query
  # per kind of row rather than one per workspace. Everything is reached
  # through the person, so a workspace they are not in is never read.
  def self.of(person)
    agents = person.agents.includes(:conversation, :campfire_bot).order(:name, :id).group_by(&:workspace_id)
    cards = person.needs_you_by_workspace
    failed = person.invocations.failed.where(updated_at: RECENT.ago..).includes(conversation: :agent).order(updated_at: :desc)
      .group_by { it.conversation.agent.workspace_id }

    person.workspaces.personal_first.includes(:memberships, :campfire_rooms).map do |workspace|
      new(workspace, agents: agents.fetch(workspace.id, []), cards: cards.fetch(workspace.id, []), failed_calls: failed.fetch(workspace.id, []))
    end
  end

  def initialize(workspace, agents:, cards:, failed_calls:)
    @workspace, @agents, @cards, @failed_calls = workspace, agents, cards, failed_calls
  end

  # How an agent stands, from its own thread's stored run: paused (the
  # person's own choice) and in error may both hold; otherwise working, idle
  # or, when Rails can't vouch for the run until the sidecar is next asked
  # (Conversation::Activity), unknown.
  def states(agent)
    run = agent.conversation&.execution_status || "idle"
    if agent.paused? then [ "paused", ("error" if run == "error") ].compact
    else [ run ]
    end
  end

  # Agents whose own thread's last run ended in an error.
  def in_error = agents.select { it.conversation&.execution_status == "error" }

  def stuck = cards.select { stuck?(it) }

  def stuck?(card) = card.created_at < STUCK_AFTER.ago || card.expires_at < STUCK_AFTER.from_now

  def held_rooms = workspace.campfire_rooms.select(&:held?).sort_by(&:held_at)

  # Campfire keeps a room's name; the app knows it only as its bots last heard it.
  def room_name(room)
    agents.filter_map { it.campfire_bot&.rooms&.dig(room.room_id.to_s).presence }.first || "Room #{room.room_id}"
  end
end
