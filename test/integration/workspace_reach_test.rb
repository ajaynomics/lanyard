require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# An agent, and everything of it, is reached through the workspaces the
# signed-in person belongs to, never through who made it (docs/design/workspaces.md).
# Bob asks by id for what sits in Alice's workspace, on every agent and thread
# route, and finds nothing: an agent Alice made, and one Bob made that is now
# in her workspace.
class WorkspaceReachTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent(name: "Bob")
    @bob = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @alice = create_user(name: "Alice")
  end
  teardown { remove_sidecar_settings }

  test "Bob finds nothing of an agent Alice made, in her workspace" do
    assert_nothing_found_by_bob @alice.agents.sole, durable_id: "21"
  end

  test "Bob finds nothing of an agent he made that is in Alice's workspace" do
    kept = @alice.personal_workspace.agents.create!(user: @bob, name: "Kept", instructions: "Help.", model: Agent.models.first)

    assert_nothing_found_by_bob kept, durable_id: "22"
  end

  test "Alice reaches an agent in her workspace, whoever made it" do
    kept = @alice.personal_workspace.agents.create!(user: @bob, name: "Kept", instructions: "Help.", model: Agent.models.first)

    assert_includes @alice.agents, kept
    assert_includes @alice.conversations, kept.conversation
    assert_not_includes @bob.agents, kept
    assert_not_includes @bob.conversations, kept.conversation
  end

  private
    def assert_nothing_found_by_bob(agent, durable_id:)
      conversation = create_conversation(agent, durable_id: durable_id)
      document = agent.documents.create!(title: "Secret").tap { it.revise("x", by: "agent") }
      invocation = conversation.invocations.create!(task_id: "7", call_id: "toolu_q", tool_name: "ask_person",
        arguments: { "question" => "Tea?" }, digest: "q", state: "awaiting_person", expires_at: 1.hour.from_now)
      answer = conversation.messages.create!(role: "assistant", content: "Done.", entry_id: 1, entry_key: "e-1")
      ids = { agent: agent.id, conversation: conversation.id, document: document.id, invocation: invocation.id }

      requests = scoped_routes.map { |verb, spec| [ verb, path_for(spec, ids) ] } +
        [ [ "GET", approval_path(invocation) ], [ "GET", new_agent_path(from: answer.id) ],
          [ "POST", agents_path(from: answer.id, request_id: "fork-1") ] ]
      assert_operator requests.size, :>, 60, "every agent and thread route is asked"

      reached = requests.filter_map do |verb, path|
        public_send(verb.downcase, path)
        "#{verb} #{path} (#{response.status})" unless response.not_found?
      rescue StandardError => error # an action that ran far enough to fail found the record
        "#{verb} #{path} (#{error.class})"
      end
      assert_empty reached, "#{reached.size} of #{requests.size} requests reached what is in Alice's workspace"
    end

    def scoped_routes
      Rails.application.routes.routes.filter_map do |route|
        spec = route.path.spec.to_s.delete_suffix("(.:format)")
        next unless spec.match?(%r{\A/(agents/:(agent_)?id|conversations/:(conversation_)?id)(/|\z)})
        route.verb.split("|").map { [ it, spec ] }
      end.flatten(1).uniq
    end

    def path_for(spec, ids)
      owner = spec.split("/")[1].singularize.to_sym
      spec.gsub(/:(\w+)/) do
        name = Regexp.last_match(1)
        next ids.fetch(owner) if name == "id" && spec.count(":") == 1
        next ids.fetch(owner) if name == "#{owner}_id"
        ids.fetch(name.delete_suffix("_id").to_sym, ids.fetch(:document)).to_s
      end
    end
end
