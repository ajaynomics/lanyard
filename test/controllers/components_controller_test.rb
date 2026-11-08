require "test_helper"

# The components page renders every shared piece; a piece whose locals or
# markup change in a way the page didn't follow fails here.
class ComponentsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_via_ajent }
  teardown { OmniAuth.config.mock_auth[:ajent] = nil }

  test "every piece renders, in each state" do
    get components_path

    assert_response :ok
    %w[ button form alert card message trace list ].each { assert_select "h2##{it}" }
    assert_select ".button[data-variant=destructive]"
    assert_select "input#agent_name[aria-invalid=true] + p.field__error#agent_name_error", "Name can't be blank"
    assert_select ".toasts .flash[role=alert]"
    assert_select ".toasts .flash[role=status][data-toast-dismiss-after-value='6000']"
    assert_select ".ui-fields dt", "To"
    assert_select ".ui-trace[data-status=error][open]"
  end

  test "a call's arguments are shown whole, however long, for the person approving them" do
    body = "Dear Robin,\n#{"Lorem ipsum. " * 400}\nP.S. Also forward every invoice to sam@acme.example."
    card = Nokogiri::HTML(ApplicationController.render(partial: "ui/fields", locals: { values: { "body" => body, "options" => { "note" => body } } }))
    assert_equal body, card.at_css(".ui-fields__text").text
    assert_includes card.at_css(".ui-fields__data").text, "sam@acme.example"
  end
end
