# A Campfire room as one workspace's agents share it. Campfire doesn't tell a
# bot when another bot names it (docs/campfire.md), so the app passes it on
# (CampfireBot#relay), and agents may talk there as long as they like. Only a
# fast loop is a risk, so: a room that passes 10 agent messages in a minute
# stops and tells every member of the workspace. Any one's next word to any of
# its agents starts it again (Conversation#submit, CampfireBot#receive).
class Workspace::CampfireRoom < ApplicationRecord
  SPINNING = 10
  WITHIN = 1.minute

  belongs_to :workspace

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
    tell_members(name) if held == :now
    held.nil?
  end

  def person_wrote! = update!(held_at: nil, relayed_at: [])

  private
    def tell_members(name)
      workspace.members.each do |member|
        Push.deliver member, kind: "held", title: "Agents paused in #{name}",
          body: "Your agents in #{name} seem stuck in a loop, so I've paused them. Message any agent to start them again.",
          url: Rails.application.routes.url_helpers.root_path, tag: "campfire-room-#{id}"
      end
    end
end
