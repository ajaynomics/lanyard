require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

class AgentPreviewTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
  end
  teardown { remove_sidecar_settings }

  test "encoded previews are plain text at phone and desktop widths" do
    short = preview("Day trip", "I&amp;#39;ve asked Lee &amp; Ren. &lt;note&gt;")
    [ 390, 1280 ].each do |width|
      page.current_window.resize_to(width, 844)
      visit conversations_path
      row = find("#row_conversation_#{short.id} .conversation-row__preview")
      assert_equal "I've asked Lee & Ren. <note>", row.text
      assert_no_selector "#row_conversation_#{short.id} .conversation-row__preview note", visible: :all
    end
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "preview length counts words and punctuation rather than their HTML spellings" do
    prefix = ("The west hall has a desk. " * 5).first(125).strip + " "
    source = prefix + "Tia hasn&amp;#39;t heard the long version yet."
    talk = preview("Longer note", source)
    expected = (prefix + "Tia hasn't heard the long version yet.").truncate(140)
    [ 390, 1280 ].each do |width|
      page.current_window.resize_to(width, 844)
      visit conversations_path
      assert_selector "#row_conversation_#{talk.id} .conversation-row__preview", exact_text: expected
    end
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  private
    def preview(name, content)
      @user.start_agent(name).conversation.tap do |conversation|
        conversation.messages.create!(entry_key: "one", entry_id: 1, role: "assistant", content: content)
      end
    end
end
