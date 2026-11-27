require "test_helper"
require "socket"
require "tmpdir"
require_relative "../test_helpers/agent_test_helper"

class ModelCatalogRolloutTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  OLD = "openai-codex/test-old".freeze
  NEW = "openai-codex/test-new".freeze
  SIGNED_OUT = "openai-chatgpt/test-signed-out".freeze

  test "both model pickers see the next sidecar's catalogue as soon as its socket replaces the old one" do
    install_sidecar_settings
    saved, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    Rails.cache.write("unrelated", "keep")
    Rails.cache.write("pi_durable/catalogue", { "models" => { OLD => model(OLD) }, "signed_in" => [ "openai-codex" ] })
    sign_in_via_ajent
    agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in

    Dir.mktmpdir do |dir|
      path = File.join(dir, "sidecar.sock")
      config = Rails.application.config.x
      config.pi_durable = config.pi_durable.merge(sidecar_url: "unix://#{path}", models: [ agent.model, OLD, NEW, SIGNED_OUT ])

      sidecar(path, OLD) do |old|
        assert_choices agent, offered: OLD, hidden: NEW
        assert_operator old.size, :<=, 1

        # Keep the endpoint, Rails process and cache; replace only the ready
        # socket and the models it serves.
        sidecar("#{path}.next", NEW) do |latest|
          File.rename("#{path}.next", path)
          assert_choices agent, offered: NEW, hidden: OLD
          assert_equal 1, latest.size
          assert_equal "keep", Rails.cache.read("unrelated")

          ModelCatalog.forget
          assert_choices agent, offered: NEW, hidden: OLD
          assert_equal 2, latest.size
        end
      end
    end
  ensure
    Rails.cache = saved
    remove_sidecar_settings
  end

  private
    def assert_choices(agent, offered:, hidden:)
      get agent_path(agent)
      assert_response :success
      assert_select "#agent_model option[value=?]", offered, count: 1
      assert_select "#agent_model option[value=?]", hidden, count: 0
      assert_select "#agent_model option[value=?]", SIGNED_OUT, count: 0

      get conversation_path(agent.conversation)
      assert_response :success
      assert_select "#command_menu [data-command=model][data-name=?]", offered, count: 1
      assert_select "#command_menu [data-command=model][data-name=?]", hidden, count: 0
      assert_select "#command_menu [data-command=model][data-name=?]", SIGNED_OUT, count: 0
    end

    # Serve only the catalogue over a local Unix socket, with no provider or network.
    def sidecar(path, id)
      server = UNIXServer.new(path)
      requests = Queue.new
      models = catalogue(id)
      thread = Thread.new do
        loop do
          client = server.accept
          begin
            request = client.gets
            while (line = client.gets) && line != "\r\n"; end
            if request&.start_with?("GET /v1/models?", "GET /v1/models ")
              requests << request
              status, body = "200 OK", models
            else
              status, body = "404 Not Found", "{}"
            end
            client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          ensure
            client.close
          end
        end
      rescue IOError, Errno::EBADF
        raise unless server.closed?
      end
      yield requests
    ensure
      server&.close
      thread&.value
    end

    def model(id) = { "id" => id, "name" => "Test model", "thinkingLevels" => [ "medium" ] }
    def catalogue(id) = { models: [ model(id), model(SIGNED_OUT) ], signedIn: [ "openai-codex" ] }.to_json
end
