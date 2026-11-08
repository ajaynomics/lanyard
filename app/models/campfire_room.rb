# A Campfire room as this person's agents share it. Campfire doesn't tell a bot
# when another bot names it (docs/campfire.md), so the app passes it on
# (CampfireBot#relay); two agents answering each other would never stop, so a
# room passes on only RELAYS_IN_A_ROW messages until a person writes there to
# one of them, or writes to any agent of theirs (Conversation#submit).
class CampfireRoom < ApplicationRecord
  # Six: a hand-off is ask, answer, follow-up, answer; three cut it off.
  RELAYS_IN_A_ROW = 6

  belongs_to :user

  # Counts one passed on, or false once the room has had its share.
  def relay!
    with_lock do
      next false if relays_in_a_row >= RELAYS_IN_A_ROW
      increment!(:relays_in_a_row)
    end
  end

  def person_wrote! = update!(relays_in_a_row: 0)
end
