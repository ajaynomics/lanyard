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

    # Where Cancel would read like the button pressed, the button says so.
    click_on "Cancel the booking"
    within("dialog#confirm[open]") do
      assert_button "Cancel the booking"
      click_on "Keep the booking"
    end
    assert_no_selector "dialog#confirm[open]"
    click_on "Confirms first"
    within("dialog#confirm[open]") { assert_button "Cancel"; click_on "Cancel" }
  end

  test "on a phone, a confirm's answers sit side by side, or one above the other when they can't share the line" do
    page.current_window.resize_to(390, 844)
    visit components_path
    { "Confirms first" => :side_by_side, "Cancel the booking" => :stacked }.each do |button, layout|
      click_on button
      boxes = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("#confirm button")].map(b => {
          const words = document.createRange(); words.selectNodeContents(b)
          return { top: b.getBoundingClientRect().top, lines: new Set([...words.getClientRects()].map(r => Math.round(r.top))).size }
        })
      JS
      assert boxes.all? { it["lines"] == 1 }, "#{button}: each answer on one line"
      assert_equal layout == :stacked, boxes.map { it["top"].round }.uniq.size == 2, button
      find("dialog#confirm[open]").send_keys(:escape)
    end
  ensure
    page.current_window.resize_to(1400, 1400)
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
