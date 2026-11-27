require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

# An agent may tell the person approving something that doesn't belong in
# what it asks to do (#169): their earlier words, or what is still open. The
# card shows it above the action, as the agent's; the action never gets it.
class NoteToApproverTest < ActionView::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include ActiveJob::TestHelper

  NOTE = "Robin said on Monday: \"book it if it's under 200\".\nStill open: <b>breakfast</b>?"
  EMAIL = { "to" => [ "hotel@example.net" ], "subject" => "Booking", "body" => "Two nights from Friday, please." }.freeze

  setup do
    ActionMailer::Base.deliveries.clear
    install_email_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    Agent.where(id: @agent.id).update_all(name: "Travel", email_name: "travel")
    @agent.reload
    @conversation = create_conversation(@agent)
  end

  teardown { remove_email_settings }

  test "the card shows the agent's note above the message, labelled as its own, as plain text with its line breaks" do
    card = card_for(receive("send_email", EMAIL.merge("note_to_approver" => NOTE), call_id: "c1"))
    note = card.at(".approval__note")

    assert_equal "Note from Travel", note.at(".approval__from").text.squish
    assert_includes note.text, "\"book it if it's under 200\""
    assert_includes note.text, "<b>breakfast</b>?", "HTML in the note is shown as text"
    assert_nil note.at("b")
    assert note.at("br"), "a line break in the note is kept"
    assert_equal 1, card.css(".approval__note ~ .ui-fields").size, "the note comes before what is approved"
    assert_not_includes card.at(".ui-fields").text, "breakfast", "and is not one of its fields"
    assert_equal %w[ To Subject Body ], card.css(".ui-fields dt").map(&:text)
  end

  test "with no note, the card is as it was" do
    plain = card_for(receive("send_email", EMAIL, call_id: "c1"))
    noted = card_for(receive("send_email", EMAIL.merge("note_to_approver" => NOTE), call_id: "c2"))

    assert_nil plain.at(".approval__note")
    noted.at(".approval__note").remove
    assert_equal normalised(plain, "c1"), normalised(noted, "c2")
    assert_equal [ "ui-card__title", "ui-fields", "ui-card__more", "ui-card__actions" ], plain.at(".ui-card").element_children.map { it["class"] }
  end

  test "the mail that goes holds no trace of the note, and another tool's call never receives it" do
    with_setting(:access, :emails, [ "alice@example.com" ]) do
      arguments = EMAIL.merge("note_to_approver" => NOTE)
      receive("send_email", arguments, call_id: "c1")
      @conversation.invocations.find_by!(call_id: "c1").approve!(by: @alice)
      receive("send_email", arguments, call_id: "c1")
      perform_enqueued_jobs(only: InvocationCallJob)

      assert_equal "done", receive("send_email", arguments, call_id: "c1")[:status]
      mail = ActionMailer::Base.deliveries.sole
      assert_equal [ "hotel@example.net" ], mail.to
      [ "Robin", "breakfast", "note_to_approver", "Note from" ].each do |text|
        assert_not_includes mail.encoded, text
        assert_not_includes mail.text_part.decoded, text
        assert_not_includes mail.html_part.decoded, text
      end
    end

    @agent.notes.remember("old", "x")
    forget = { "key" => "old", "note_to_approver" => "You asked me to clear this yesterday." }
    receive("forget_note", forget, call_id: "c2")
    @conversation.invocations.find_by!(call_id: "c2").approve!(by: @alice)
    outcome = receive("forget_note", forget, call_id: "c2")

    assert_equal({ forgotten: "old" }, outcome[:result], "ForgetNote#call takes key: alone, so a note passed on would raise")
    assert_nil @agent.notes.find_by(key: "old")
  end

  # Allow binds the card the person saw, note included: a run whose note differs
  # is another call, refused by the digest check before anything acts.
  test "a call whose note changed after Allow is refused, and nothing is sent" do
    with_setting(:access, :emails, [ "alice@example.com" ]) do
      shown = EMAIL.merge("note_to_approver" => "Robin agreed to two nights.")
      receive("send_email", shown, call_id: "c1")
      invocation = @conversation.invocations.find_by!(call_id: "c1")
      assert_includes card_for(nil).at(".approval__note").text, "Robin agreed to two nights."
      invocation.approve!(by: @alice)

      changed = shown.merge("note_to_approver" => "Robin agreed to five nights.")
      assert_equal shown.except("note_to_approver"), changed.except("note_to_approver")
      assert_raises(Invocation::Conflict) { receive("send_email", changed, call_id: "c1") }
      perform_enqueued_jobs(only: InvocationCallJob)

      assert invocation.reload.approved?, "the approved call has not run"
      assert_equal shown, invocation.arguments
      assert_empty ActionMailer::Base.deliveries
    end
  end

  test "a note is at most 1,000 characters" do
    assert_equal "waiting", receive("send_email", EMAIL.merge("note_to_approver" => "a" * 1_000), call_id: "c1")[:status]
    outcome = receive("send_email", EMAIL.merge("note_to_approver" => "a" * 1_001), call_id: "c2")
    assert outcome[:isError]
    assert_match(/note_to_approver/, outcome[:result][:error])
  end

  test "every tool that asks for approval takes the note, no other does, and it adds no tool or changes who is asked" do
    names = @agent.conversation.definition[:tools].pluck(:name)
    declared = Tool::Catalog::TOOLS.values + Tool::Catalog::CONCOURSE + Tool::Catalog::SAVED_SIGN_INS + Tool::Catalog::ALWAYS +
      Tool::Catalog::CANVAS + Tool::Catalog::CAMPFIRE + Tool::Catalog::EMAIL + Tool::Catalog::PHONE + Tool::Catalog::TELEGRAM + Tool::Catalog::CALENDAR +
      Tool::Catalog::QUESTIONS
    declared.each do |tool|
      assert_equal tool.asks == :approval, tool.declaration[:parameters]["properties"].key?("note_to_approver"), tool.tool_name
      assert_not_includes tool.declaration[:parameters]["required"], "note_to_approver", tool.tool_name
    end
    assert_not_includes names, "note_to_approver"
    assert_operator names.size, :<=, Agent::TOOL_LIMIT

    with_setting(:access, :emails, [ "alice@example.com" ]) do
      inside = { "to" => [ "alice@example.com" ], "subject" => "Trip", "body" => "Booked.", "note_to_approver" => "FYI" }
      receive("send_email", inside, call_id: "in")
      perform_enqueued_jobs(only: InvocationCallJob)
      assert_equal "done", receive("send_email", inside, call_id: "in")[:status], "mail to the install's own people still goes at once"

      plain = @conversation.invocations.find_by!(call_id: receive_id("send_email", EMAIL, "out1"))
      noted = @conversation.invocations.find_by!(call_id: receive_id("send_email", EMAIL.merge("note_to_approver" => "FYI"), "out2"))
      assert noted.awaiting_person?
      assert_equal plain.always_choices, noted.always_choices
      assert_equal plain.recipients, noted.recipients
    end
  end

  private
    def receive(tool, arguments, call_id:)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    def receive_id(tool, arguments, call_id) = receive(tool, arguments, call_id: call_id) && call_id

    def card_for(_outcome)
      invocation = @conversation.invocations.order(:id).last
      Nokogiri::HTML5.fragment(render(partial: "invocations/invocation", locals: { invocation: invocation }))
    end

    # The same card for another call: its own ids and paths, and the blank space between tags, aside.
    def normalised(card, call_id)
      invocation = @conversation.invocations.find_by!(call_id: call_id)
      card.to_html.gsub(invocation.dom_target, "TARGET").gsub("/invocations/#{invocation.id}/", "/invocations/ID/").gsub(/>\s+</, "><")
    end
end
