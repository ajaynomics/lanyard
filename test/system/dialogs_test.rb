require "application_system_test_case"

# The shared pieces that only a browser can show work: a confirm asks in the
# page, a notice goes by itself, an alert stays until closed.
class DialogsTest < ApplicationSystemTestCase
  setup { sign_in_via_ajent }
  teardown { OmniAuth.config.mock_auth[:ajent] = nil }

  test "a confirm asks in a dialog named for its button; Cancel and Escape say no" do
    visit components_path
    click_on "Confirms first"
    within("dialog#confirm[open]") do
      assert_text "Remove this? It can't be undone."
      assert_button "Confirms first"
      click_on "Cancel"
    end
    assert_no_selector "dialog#confirm[open]"

    click_on "Confirms first"
    find("dialog#confirm[open]").send_keys(:escape)
    assert_no_selector "dialog#confirm[open]"

    click_on "Confirms first"
    within("dialog#confirm[open]") { click_on "Confirms first" }
    assert_no_selector "dialog#confirm[open]"
    assert_current_path components_path
  end

  test "a notice goes by itself, an alert stays until closed, and neither moves the page" do
    visit components_path
    top = page.evaluate_script("document.querySelector('h1').getBoundingClientRect().top")
    page.execute_script(<<~JS)
      document.getElementById("flash").innerHTML = document.querySelector(".components__toasts .toasts").innerHTML
        .replace('data-toast-dismiss-after-value="6000"', 'data-toast-dismiss-after-value="300"')
    JS
    assert_selector "#flash .flash[role=alert]"
    assert_equal top, page.evaluate_script("document.querySelector('h1').getBoundingClientRect().top")
    assert_no_selector "#flash .flash[role=status]", wait: 3
    find("#flash .flash__close[aria-label=Dismiss]").click
    assert_no_selector "#flash .flash"
  end
end
