require "test_helper"

# A saved sign-in's site is the host its page must be on. People save it as a
# full address or, often, just the domain.
class PassboltSignInTest < ActiveSupport::TestCase
  test "a full address, a bare domain, or one with a path gives the site's host" do
    assert_equal "login.bank.example", host("https://login.bank.example/account/login")
    assert_equal "bank.example", host("bank.example")
    assert_equal "bank.example", host(" Bank.Example. ")
    assert_equal "bank.example", host("bank.example/login")
  end

  test "an empty or unreadable address has no site" do
    assert_nil host("")
    assert_nil host("https://")
    assert_nil host("bank example")
  end

  test "security questions are custom fields: the question in the metadata, the answer in the secret, joined by id" do
    entry = { "metadata" => { "custom_fields" => [
                { "id" => "a", "type" => "text", "metadata_key" => "First pet?" },
                { "id" => "b", "type" => "text", "metadata_key" => "Unanswered" },
                { "id" => "c", "type" => "text" } ] },
              "secret" => { "custom_fields" => [
                { "id" => "a", "type" => "text", "secret_value" => "Rex" },
                { "id" => "c", "type" => "text", "secret_key" => "Hidden question", "secret_value" => 1234 } ] } }

    assert_equal [ { "question" => "First pet?", "answer" => "Rex" }, { "question" => "Hidden question", "answer" => "1234" } ],
      DurableAssistants::Passbolt.answers_in(entry)
    assert_empty DurableAssistants::Passbolt.answers_in({ "name" => "No fields" })
  end

  test "a sign-in printed shows no password or answer" do
    sign_in = DurableAssistants::Passbolt::SignIn.new(id: "1", name: "Bank", address: "bank.example", username: "maya",
      password: "secret", answers: [ { "question" => "First pet?", "answer" => "Rex" } ])
    assert_no_match(/secret|Rex/, sign_in.inspect)
  end

  private
    def host(address)
      DurableAssistants::Passbolt::SignIn.new(id: "1", name: "Bank", address: address, username: "maya", password: "secret").host
    end
end
