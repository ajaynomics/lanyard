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
