require "test_helper"
require_relative "../test_helpers/forge_socket_test_helper"

class ForgeTransportTest < ActiveSupport::TestCase
  include ForgeSocketTestHelper

  PATH = "/run/sample/bridge.sock"
  CONTEXT = { agent_id: 19, workspace_id: 2, conversation_id: 3, invocation_id: 4, task_id: "5", call_id: "call_6" }.freeze
  OPERATION = { "verb" => "pr", "repo" => "sample/project", "number" => 8 }.freeze

  test "a protected local socket receives separate server context and operation" do
    with_fake_forge_socket(PATH) do |socket|
      assert_equal [ { "number" => 8 }, nil ], transmit
      assert_equal({ "context" => CONTEXT.stringify_keys, "operation" => OPERATION }, JSON.parse(socket.writes.sole))
    end
  end

  test "unsafe socket and directory owners or modes, file type and peer receive no data" do
    [ { uid: 1000 }, { mode: 0o666 }, { socket: false }, { peer_uid: 1000 }, { dir_mode: 0o777 }, { dir_uid: 1000 } ].each do |options|
      with_fake_forge_socket(PATH, **options) do |socket|
        assert_raises(IOError) { transmit }
        assert_empty socket.writes
      end
    end
  end

  test "rejects oversized requests without writing and accepts up to a 16 KiB reply line" do
    with_fake_forge_socket(PATH, reply: ->(_) { { "data" => "x" * 8_000 } }) do |socket|
      assert_raises(IOError) { transmit(operation: OPERATION.merge("data" => "x" * 16_384)) }
      assert_empty socket.writes
      assert_equal 8_000, transmit.first.fetch("data").size
    end
  end

  test "replies must be one bounded UTF-8 JSON object with no duplicate keys" do
    bad = [ "{\"data\":\"#{'x' * 16_384}\"}\n", "{}", "[]\n", "{\"data\":\"\xFF\"}\n".b, "{\"status\":1,\"status\":2}\n" ]
    bad.each do |line|
      with_fake_forge_socket(PATH, reply: ->(_) { line }) do
        assert_raises(IOError) { transmit }
      end
    end
  end

  test "one binary frame is read only on a successful framed verb" do
    with_fake_forge_socket(PATH, reply: ->(_) { { status: "ok", bytes: 3 } }, frame: "abc") do
      assert_equal [ { "status" => "ok", "bytes" => 3 }, "abc" ], transmit(reply_frame_limit: 5)
    end
    with_fake_forge_socket(PATH, reply: ->(_) { { status: "ok", bytes: 3 } }, frame: "abc", length: 100) do
      assert_raises(IOError) { transmit(reply_frame_limit: 5) }
    end
    with_fake_forge_socket(PATH, reply: ->(_) { { status: "refused", reason: "bounds" } }) do
      assert_equal [ { "status" => "refused", "reason" => "bounds" }, nil ], transmit(reply_frame_limit: 5)
    end
  end

  private
    def transmit(operation: OPERATION, reply_frame_limit: nil)
      DurableAssistants::ForgeTransport.call(PATH, context: CONTEXT, operation:, timeout: 30, reply_frame_limit:)
    end
end
