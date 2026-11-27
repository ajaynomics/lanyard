require "application_system_test_case"

# A key pressed before the controller that answers it has connected is lost
# (ActOnSettledPage): on a loaded CI, ⌘, reached a page whose shortcuts had
# not loaded yet, and Settings never opened.
class SettledPageTest < ApplicationSystemTestCase
  setup { sign_in_via_ajent }
  teardown { OmniAuth.config.mock_auth[:ajent] = nil }

  test "a key press waits for the controller that answers it" do
    visit root_path
    wait_until { page.evaluate_script("!!window.Stimulus?.getControllerForElementAndIdentifier(document.body, 'shortcuts')") }
    # As on a slow load: the shortcuts arrive a second after the page.
    page.execute_script(<<~JS)
      const shortcuts = Stimulus.getControllerForElementAndIdentifier(document.body, "shortcuts").constructor
      Stimulus.unload("shortcuts")
      setTimeout(() => Stimulus.register("shortcuts", shortcuts), 1000)
    JS

    find("body").send_keys([ :control, "," ])
    assert_current_path settings_path
  end

  # Turbo sends a form by fetch, so the click returned before the answer came,
  # and a loaded CI spent the next check's whole wait on the server (CI 9895,
  # 9908). Read straight after the click, the answer is already on the page.
  test "a click that submits a form returns once its answer is on the page" do
    agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the person signed in
    visit new_agent_skill_path(agent)
    # As on a slow server: every answer arrives half a second late.
    page.execute_script(<<~JS)
      const fetch = window.fetch
      window.fetch = (...request) => fetch(...request).then(response => new Promise(resolve => setTimeout(() => resolve(response), 500)))
    JS
    fill_in "Or paste a SKILL.md", with: "---\nname: trip\ndescription: Use when planning a trip.\n---\n\n# Trip\n"
    within("#upload_skill") { click_on "Add" }

    assert_text "Added the trip skill.", wait: 0
  end

  # A confirm dialog's close event comes a task after the button that closes
  # it. Turbo sent the form only then, so the click returned with nothing on
  # its way, and a loaded CI spent the next check's whole wait on the server
  # (CI 10153, Concourse's Disconnect).
  test "a click that answers a confirm returns once the form it sends is answered" do
    agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the person signed in
    agent.skills.create!(name: "trip", description: "Use when planning a trip.", body: "# Trip")
    visit agent_skills_path(agent)
    # As on a loaded browser: the dialog's close event runs half a second late.
    page.execute_script(<<~JS)
      const dialog = document.getElementById("confirm")
      dialog.addEventListener("close", event => {
        event.stopImmediatePropagation()
        setTimeout(() => dialog.dispatchEvent(new Event("close")), 500)
      }, { capture: true, once: true })
    JS
    click_on "Remove"
    within("dialog#confirm[open]") { click_on "Remove" }

    assert_text "Removed the trip skill.", wait: 0
  end

  test "a wait that runs out fails, saying what it waited for" do
    error = assert_raises(Minitest::Assertion) { wait_until("nothing", within: 0.1) { false } }
    assert_equal "waited 0.1 seconds for nothing", error.message
    error = assert_raises(Minitest::Assertion) { wait_until(within: 0.1) { false } }
    assert_match %r{\Awaited 0.1 seconds for the condition at test/system/settled_page_test.rb:\d+\z}, error.message
  end
end
