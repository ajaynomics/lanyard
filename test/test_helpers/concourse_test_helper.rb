# Concourse and Ajent, stubbed at the HTTP boundary with WebMock. The agent's
# agent is `acme/assistant` in organization `acme`, agent number 7.
module ConcourseTestHelper
  ORIGIN = "https://concourse.example".freeze
  TOKEN_URL = "https://id.example/oauth/token".freeze
  ACCESS_TOKEN = "synthetic-concourse-access-token".freeze
  IDENTITY = { "owner_id" => 3, "owner" => "maya", "organization" => "acme", "agent_id" => 7, "oauth_client_id" => "client-1",
               "handle" => "assistant", "release_line" => 3, "network_agent" => "concourse/network-acme", "prefix" => "acme" }.freeze

  def create_concourse_agent(agent, **attributes)
    agent.create_concourse_agent!(organization: "acme", handle: "acme/assistant", client_id: "client-1", client_secret: "secret-1", **attributes)
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

  def concourse_task(id: "task-1", context_id: "ctx-1", state: "TASK_STATE_SUBMITTED", caller: "acme/friend", messages: [ [ "m-1", "Hello" ] ], status_message: nil, metadata: {})
    history = messages.map { |id_, text| { "messageId" => id_, "contextId" => context_id, "taskId" => id, "role" => "ROLE_USER", "parts" => [ { "text" => text } ] } }
    status = { "state" => state, "timestamp" => "2026-11-07T10:00:00.000Z" }
    status["message"] = { "messageId" => status_message.first, "role" => "ROLE_AGENT", "parts" => [ { "text" => status_message.last } ] } if status_message
    { "id" => id, "contextId" => context_id, "status" => status, "history" => history, "artifacts" => [],
      "metadata" => { "concourse.caller" => caller }.merge(metadata) }
  end
end
