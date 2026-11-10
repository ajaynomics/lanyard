# A Campfire room as this person's agents share it. Campfire doesn't tell a bot
# when another bot names it (docs/campfire.md), so the app passes it on
# (CampfireBot#relay), and agents may talk there as long as they like. Only a
# fast loop is a risk, so: a room that passes 10 agent messages in a minute
# stops and tells its person. Their next word to any agent starts it again
# (Conversation#submit, CampfireBot#receive).
class CampfireRoom < ApplicationRecord
  SPINNING = 10
  WITHIN = 1.minute

  belongs_to :user

  def self.person_wrote! = update_all(held_at: nil, relayed_at: [])

  def held? = held_at.present?

  # Counts one passed on, or holds the room and returns false once it spins.
  def relay!(name)
    held = with_lock do
      next :already if held?
      recent = relayed_at.select { it > WITHIN.ago.to_f }
      next :now if recent.size >= SPINNING && update!(held_at: Time.current, relayed_at: [])
      update!(relayed_at: recent << Time.current.to_f)
      nil
    end
    tell_person(name) if held == :now
    held.nil?
  end

  def person_wrote! = update!(held_at: nil, relayed_at: [])

  private
    def tell_person(name)
      Push.deliver user, kind: "held", title: "Agents paused in #{name}",
        body: "Your agents in #{name} seem stuck in a loop, so I've paused them. Message any agent to start them again.",
        url: Rails.application.routes.url_helpers.root_path, tag: "campfire-room-#{id}"
    end
end
