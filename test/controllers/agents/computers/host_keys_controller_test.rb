require "test_helper"
require_relative "../../../test_helpers/agent_test_helper"

# An SSH computer's page: the folder shown plainly, the sidecar's key to add
# on the machine, and the machine's host key, trusted once as the person saw it.
class Agents::Computers::HostKeysControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFakeFake durable-assistants".freeze
  FINGERPRINT = "SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8".freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    stub_request(:get, "#{SIDECAR}/v1/computers/ssh/key").to_return(body: { publicKey: KEY }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "the person picks a machine over SSH, fills it in, and the page says plainly where the agent works and that it is not isolated" do
    patch agent_computer_path(@agent), params: { computer: { provider: "ssh", state: "off" } }
    follow_redirect!
    assert_select "#computer input[name='computer[ssh_host]']"
    assert_select "#ssh", /works directly in a folder on a real machine/
    assert_select "turbo-frame#ssh_host_key", { count: 0 }, "nothing to reach yet"

    patch agent_computer_path(@agent), params: { computer: { provider: "ssh", state: "on" } }
    assert_match(/can't be blank/, flash[:alert])

    patch agent_computer_path(@agent), params: { computer: { provider: "ssh", state: "on", ssh_host: "homeserver", ssh_user: "jordan", folder: "/home/jordan/work" } }
    follow_redirect!
    assert_select "#computer", /reads, writes and runs commands as jordan on homeserver, in \/home\/jordan\/work\./
    assert_select "#ssh code", "jordan@homeserver:/home/jordan/work"
    assert_select "#ssh", /Not isolated.*can do anything that user can on that machine.*kept out of the docker group/m
    assert_select "turbo-frame#ssh_host_key[src=?][loading=lazy]", agent_computer_host_key_path(@agent)

    get agent_path(@agent)
    assert_select "#delete_agent", /Its folder on homeserver is left as it is\./
  end

  test "a machine whose key is not yet trusted shows its fingerprint to compare, and the person trusts that key alone" do
    ssh_computer
    stub_request(:get, "#{SIDECAR}/v1/computers/ssh/host?host=homeserver&user=jordan").to_return(body: { trusted: false, fingerprints: [ FINGERPRINT ] }.to_json)

    get agent_computer_host_key_path(@agent)
    assert_select "turbo-frame#ssh_host_key code", KEY
    assert_select "turbo-frame#ssh_host_key", /Add this key to ~jordan\/.ssh\/authorized_keys on homeserver/
    assert_select "turbo-frame#ssh_host_key code", FINGERPRINT
    assert_select "form[action=?] input[name='fingerprints[]'][value=?]", agent_computer_host_key_path(@agent), FINGERPRINT

    trusted = stub_request(:post, "#{SIDECAR}/v1/computers/ssh/host")
      .with(body: { host: "homeserver", user: "jordan", fingerprints: [ FINGERPRINT ] }.to_json)
      .to_return(body: { trusted: true, fingerprints: [ FINGERPRINT ] }.to_json)
    post agent_computer_host_key_path(@agent), params: { fingerprints: [ FINGERPRINT ] }
    assert_requested trusted
    assert_redirected_to agent_computer_path(@agent)
    assert_equal "Trusted homeserver.", flash[:notice]
  end

  test "a key that changed since the person looked is not trusted, and a machine out of reach says so" do
    ssh_computer
    stub_request(:post, "#{SIDECAR}/v1/computers/ssh/host").to_return(status: 409, body: { error: "host_key_changed" }.to_json)
    post agent_computer_host_key_path(@agent), params: { fingerprints: [ FINGERPRINT ] }
    assert_match(/not the one you saw\. Nothing was trusted/, flash[:alert])

    stub_request(:get, "#{SIDECAR}/v1/computers/ssh/host?host=homeserver&user=jordan").to_return(status: 502, body: { error: "host_unreachable" }.to_json)
    get agent_computer_host_key_path(@agent)
    assert_select "turbo-frame#ssh_host_key", /homeserver could not be reached from the app's machine/
  end

  test "there is nothing to trust for a computer that is not over SSH, nor for someone else's agent" do
    @agent.create_computer!(provider: "local", state: "on")
    get agent_computer_host_key_path(@agent)
    assert_response :not_found

    other = create_user(name: "Robin").agents.sole
    other.create_computer!(provider: "ssh", state: "on", ssh_host: "homeserver", ssh_user: "robin", folder: "/home/robin")
    post agent_computer_host_key_path(other), params: { fingerprints: [ FINGERPRINT ] }
    assert_response :not_found
  end

  private
    def ssh_computer
      @agent.create_computer!(provider: "ssh", state: "on", ssh_host: "homeserver", ssh_user: "jordan", folder: "/home/jordan/work")
    end
end
