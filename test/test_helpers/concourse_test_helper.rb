require_relative "fake_concourse"

# Concourse and Ajent, stubbed at the HTTP boundary with WebMock. The agent's
# agent is `acme/assistant` in organization `acme`, agent number 7.
module ConcourseTestHelper
  ORIGIN = "https://concourse.example".freeze
  TOKEN_URL = "https://id.example/oauth/token".freeze
  ACCESS_TOKEN = "synthetic-concourse-access-token".freeze
  IDENTITY = { "owner_id" => 3, "owner" => "maya", "organization" => "acme", "agent_id" => 7, "oauth_client_id" => "client-1",
               "handle" => "assistant", "release_line" => 3, "network_agent" => "concourse/network-acme", "prefix" => "acme" }.freeze

  def create_concourse_agent(agent, **attributes)
    agent.concourse_agents.create!(organization: "acme", handle: "acme/assistant", client_id: "client-1", client_secret: "secret-1", **attributes)
  end

  # A second identity, `example/assistant` in organization `example`, with its
  # own client and access token. Its calls carry SECOND_TOKEN.
  SECOND_TOKEN = "synthetic-second-access-token".freeze

  def create_second_network(agent, **attributes)
    stub_request(:post, TOKEN_URL)
      .with(headers: { "Authorization" => "Basic #{Base64.strict_encode64("client-2:secret-2")}" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { access_token: SECOND_TOKEN, token_type: "Bearer", expires_in: 3600, scope: "concourse" }.to_json)
    stub_request(:get, "#{ORIGIN}/api/identity").with(headers: { "Authorization" => "Bearer #{SECOND_TOKEN}" })
      .to_return(headers: { "Content-Type" => "application/json" },
                 body: IDENTITY.merge("organization" => "example", "agent_id" => 8, "oauth_client_id" => "client-2", "prefix" => "example").to_json)
    agent.concourse_agents.create!(organization: "example", handle: "example/assistant", client_id: "client-2", client_secret: "secret-2", **attributes)
  end

  def stub_concourse_token(token: ACCESS_TOKEN, expires_in: 3600)
    stub_request(:post, TOKEN_URL)
      .with(body: { grant_type: "client_credentials", scope: "concourse", resource: ORIGIN },
            headers: { "Authorization" => "Basic #{Base64.strict_encode64("client-1:secret-1")}" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { access_token: token, token_type: "Bearer", expires_in: expires_in, scope: "concourse" }.to_json)
  end

  def stub_concourse_identity(**changes)
    stub_concourse(:get, "api/identity", IDENTITY.merge(changes.stringify_keys))
  end

  # The token and identity every call starts with, then the call itself.
  def stub_concourse(method, path, body, status: 200)
    stub_request(method, "#{ORIGIN}/#{path}").with(headers: { "Authorization" => "Bearer #{ACCESS_TOKEN}" })
      .to_return(status: status, headers: { "Content-Type" => "application/json" }, body: body.to_json)
  end

  def stub_concourse_session
    stub_concourse_token
    stub_concourse_identity
  end

  # The join's stand-in (FakeConcourse) answering for Concourse and for
  # Ajent's token address.
  def stub_fake_concourse(**options)
    FakeConcourse.new(redirect_uri: ConcourseAgent::Join.redirect_uri, token_endpoint: TOKEN_URL, **options).tap do |fake|
      stub_request(:any, %r{\A#{Regexp.escape(ORIGIN)}/}).to_rack(fake)
      stub_request(:post, TOKEN_URL).to_rack(fake)
    end
  end

  # Concourse as it was in the case of #86: it takes each send to `to`, then
  # gives no answer before the app stops waiting, as if it hung. Its network
  # agent's receipt (`delivery`, by messageId) lists what it took as a task,
  # from `listed_after` on, and the task reads back. The messages it took,
  # each with its task's id.
  def concourse_taking_then_hanging(to: "acme/travel", listed_after: 0.seconds, first_task: 9)
    taken = []
    stub_request(:post, "#{ORIGIN}/a2a/acme/#{to}").with(headers: { "Authorization" => "Bearer #{ACCESS_TOKEN}" }).to_return do |request|
      message = JSON.parse(request.body).dig("params", "message")
      taken << { "messageId" => message["messageId"], "taskId" => message["taskId"] || "task-#{first_task + taken.size}",
                 "text" => message.dig("parts", 0, "text"), "listed_at" => Time.current + listed_after }
      raise Net::ReadTimeout
    end
    stub_request(:post, "#{ORIGIN}/a2a/acme/concourse/network-acme").with(headers: { "Authorization" => "Bearer #{ACCESS_TOKEN}" }).to_return do |request|
      asked = JSON.parse(request.body).dig("params", "message", "parts", 0, "data")
      found = taken.find { it["messageId"] == asked["messageId"] && !it["listed_at"].after?(Time.current) }
      receipt = found ? { state: "accepted", accepted: true, taskId: found["taskId"], taskStatus: "TASK_STATE_SUBMITTED" } : { state: "absent", accepted: false }
      reply = { messageId: "network-1", role: "ROLE_AGENT", parts: [ { mediaType: "application/json", data: receipt.merge(operation: "delivery") } ] }
      { body: { jsonrpc: "2.0", id: "x", result: { message: reply } }.to_json, headers: { "Content-Type" => "application/json" } }
    end
    stub_request(:get, %r{\A#{Regexp.escape(ORIGIN)}/api/tasks/}).to_return do |request|
      id = request.uri.path.split("/").last
      { body: concourse_task(id: id, context_id: "ctx-#{id}", caller: "acme/assistant").to_json, headers: { "Content-Type" => "application/json" } }
    end
    taken
  end

  def concourse_task(id: "task-1", context_id: "ctx-1", state: "TASK_STATE_SUBMITTED", caller: "acme/friend", messages: [ [ "m-1", "Hello" ] ], status_message: nil, metadata: {})
    history = messages.map { |id_, text| { "messageId" => id_, "contextId" => context_id, "taskId" => id, "role" => "ROLE_USER", "parts" => [ { "text" => text } ] } }
    status = { "state" => state, "timestamp" => "2026-11-07T10:00:00.000Z" }
    status["message"] = { "messageId" => status_message.first, "role" => "ROLE_AGENT", "parts" => [ { "text" => status_message.last } ] } if status_message
    { "id" => id, "contextId" => context_id, "status" => status, "history" => history, "artifacts" => [],
      "metadata" => { "concourse.caller" => caller }.merge(metadata) }
  end
end
