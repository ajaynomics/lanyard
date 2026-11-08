# Every shared piece of the interface on one page, in each of its states, so a
# change that drifts from the rest shows at a glance (docs/design.md). Routed
# only in development and test: a test renders it, so a piece whose locals
# change breaks the build rather than this page.
class ComponentsController < ApplicationController
  def show
    @invalid = Current.user.agents.new.tap { it.validate }
    # Unsaved, one for each avatar colour.
    @agents = [ "Assistant", "Trip planner", "Researcher", "Ops", "Écrivain", "Home & garden", "Q", "Inbox zero" ]
      .each_with_index.map { |name, index| Agent.new(id: index, name: name) }
    @conversation = Conversation.new(id: 1, agent: @agents.second)
    @document = document(1, "Lisbon in three days", "markdown", nil,
      "# Lisbon\n\n- **Day 1:** Alfama and the castle\n- **Day 2:** Belém\n", "# Lisbon\n\n- **Day 1:** Alfama\n- **Day 2:** Belém\n- **Day 3:** Sintra\n")
    @code = document(2, "Packing check", "code", "ruby", "PACKING = %w[ passport charger ]\n\ndef packed?(bag) = (PACKING - bag).empty?\n")
  end

  private
    # Unsaved, with its versions built in memory, as the agent and the person wrote them.
    def document(id, title, kind, language, *bodies)
      Document.new(id: id, title: title, kind: kind, language: language, agent: @agents.second).tap do |document|
        bodies.each_with_index do |body, index|
          document.versions.build(number: index + 1, body: body, author: index.odd? ? "person" : "agent", created_at: Time.utc(2026, 11, 2, 9 + index, 41))
        end
      end
    end
end
