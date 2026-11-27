require "test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# The command line itself, through the stand-in `passbolt` on PATH.
class PassboltTest < ActiveSupport::TestCase
  include PassboltTestHelper

  setup { install_fake_passbolt }
  teardown { remove_fake_passbolt }

  test "a share goes without --json, which only list, get and create accept, and prints nothing to read" do
    assert_nil DurableAssistants::Passbolt.send(:run, nil, "share", "resource", "--id", "7f0c", "--type", "1", "--group", "g1")
    assert_match "ARGS share resource --id 7f0c --type 1 --group g1 --mfaMode none", passbolt_calls
  end

  test "list and get still ask for --json and read it; a save reads passbolt-save's" do
    assert_equal [ "Bank" ], DurableAssistants::Passbolt.sign_ins(nil).map(&:name)
    assert_equal PASSWORD, DurableAssistants::Passbolt.sign_in(nil, "7f0c").password
    assert_equal({ "id" => "9a1" }, DurableAssistants::Passbolt.save(nil, name: "Library", address: "library.example", username: "maya", password: PASSWORD))
    assert_equal 3, passbolt_calls.scan(/^ARGS (list|get) resource .* --json --mfaMode none/).size
    assert_no_match(/^ARGS create/, passbolt_calls)
  end

  # The vault's Go code refuses, as it connects, a server that lands inside
  # the install (passbolt-save/vaultdial), except for the hosts named here.
  test "the vault's Go code may reach inside only the operator's hosts, and the install's own server when it is the one called" do
    install_fake_native_vault
    x = Rails.application.config.x
    saved, x.connectors = x.connectors, x.connectors.to_h.merge(internal_hosts: "wiki-two, Notes:8443 bad:port")
    acorn = Workspace.create!(name: "Acorn", passbolt_url: "https://vault.example.test", passbolt_private_key: "acorn-key", passbolt_passphrase: "acorn-pass")

    DurableAssistants::Passbolt.save(nil, name: "Library", address: "library.example", username: "maya", password: PASSWORD)
    DurableAssistants::Passbolt.save(acorn, name: "Library", address: "library.example", username: "maya", password: PASSWORD)
    x.passbolt[:url] = "https://passwords.example:8443"
    DurableAssistants::Passbolt.sign_ins(nil)

    assert_equal [ "wiki-two,notes:8443,passwords.example:80", "wiki-two,notes:8443" ], passbolt_calls.lines.grep(/^INSIDE /).map { it.split.last }
    assert_equal [ "wiki-two,notes:8443", "wiki-two,notes:8443,passwords.example:8443" ], @native_inside
  ensure
    x.connectors = saved
  end

  # Every account on the host can read a process's arguments, so no call may
  # put a secret there, however it is spelled; nothing runs.
  test "a secret flag in the arguments is refused before anything runs" do
    [ %w[ --password x ], %w[ --password=x ], %w[ -p x ], %w[ -px ], %w[ --secret-field password=x ],
      %w[ --userPassword x ], %w[ --userPrivateKey=x ], %w[ --mfaTotpToken x ] ].each do |flags|
      assert_raises(ArgumentError, flags.join(" ")) { DurableAssistants::Passbolt.send(:run, nil, "create", "resource", "--name", "Library", *flags) }
    end
    assert_empty passbolt_calls
  end
end
