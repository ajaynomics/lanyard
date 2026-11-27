require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"
require_relative "../test_helpers/mcp_test_helper"
require_relative "../test_helpers/voipms_test_helper"

# Can a member of one workspace see or reach anything of another? Two shared
# workspaces: A, which Alice owns and Bob is a member of, and B, which Carol
# owns and Dave is a member of. B holds one of every record that hangs off a
# workspace, its agents or its people, each carrying MARK. Bob, working in A,
# asks for each of them every way the app offers one (docs/design/workspaces.md):
#
# - every route that takes a parameter, found from Rails.application.routes,
#   so a route added later is asked too, or fails here until it says where
#   its record comes from (CrossWorkspaceRoutesTest);
# - the live streams (CrossWorkspaceStreamsTest);
# - every tool an agent in A calls through the invocation ledger, as the
#   sidecar calls it (CrossWorkspaceToolsTest).
#
# He finds nothing: not found (or a redirect that names nothing of B), B's
# records unchanged, and MARK in no answer. What an install deliberately
# shares between its workspaces today is SHARED_ACROSS_WORKSPACES, and the
# test there fails when something is shared that is not on it.
module CrossWorkspaceWorld
  include AgentTestHelper

  # In every B record a person could be shown. Never in A's.
  MARK = "zqxb".freeze

  # Shared by every workspace of an install today, each with why. A setting
  # group (config/application.rb, config.x.<name>) is install-wide by
  # construction: each is on this list or INSTALL_PLUMBING, so a new one has to
  # say which (CrossWorkspaceSharedTest).
  SHARED_ACROSS_WORKSPACES = {
    pi_durable: "The model subscriptions (Claude, ChatGPT) and the Claude API key: one per install, held by the sidecar " \
      "(Subscription, ApiKey, /subscriptions), which every workspace's agents use and any admitted person manages; " \
      "a workspace's calls are only billed to its payer (docs/billing.md). " \
      "Removed in step 2: per-workspace secrets and identities.",
    passbolt: "The install's Passbolt user (and its key), whose folders a workspace's agents with a screen list and fill " \
      "from unless the agent has its own user (a console, docs/passwords.md) or its workspace does (its page, " \
      "Workspace::VaultUser); CrossWorkspaceSecretsTest holds that one workspace's is never another's. " \
      "Shared only where a workspace sets none of its own.",
    install_connectors: "The install's connectors (wiki, CRM), turned on in a workspace by its owner or the office's " \
      "(McpServer.turn_on), in its owner's name, with the install's address, and its key only where the office's owner " \
      "owns the workspace; any other sets its own (Workspace::InstallConnector); CrossWorkspaceSecretsTest holds that one " \
      "workspace's key is never another's. " \
      "Shared only where a workspace sets none of its own.",
    office: "The one person (OFFICE__OWNER_EMAIL) whose workspaces use the install's office keys (install_connectors), " \
      "and who turns one on in another's workspace they are in; it changes nobody's sign-in or admission. " \
      "Shared only where a workspace sets none of its own.",
    concourse: "One Concourse server (its origin and token address): every workspace's agents join organizations on it. " \
      "A workspace names its home network; an identity in any other organization is a bridge, which speaks only once the " \
      "workspace's owner approves it, and each send onto it asks a person (ConcourseAgent::Bridge, docs/design/workspaces.md, 2.3 and 3). " \
      "Removed in step 2: per-workspace secrets and identities.",
    campfire: "The install's Campfire and its administrator, for each workspace that names no Campfire of its own " \
      "(Workspace#campfire): there every open room, and everyone signed in, is visible to all. A bot relays to, makes rooms " \
      "with and pauses for only its own workspace's agents and people (CampfireBot, campfire_make_room, Workspace::CampfireRoom). " \
      "Removed in step 2: per-workspace secrets and identities.",
    bluebubbles: "One iMessage account (BlueBubbles) for the install: an agent in any workspace given the iMessage tools " \
      "reads and sends as the same person. Removed in step 2: per-workspace secrets and identities.",
    voipms: "The install's voip.ms account sends the texts of every workspace's agents that names no account of its own " \
      "(Workspace#voipms_account, read from the vault as its agent); each agent has its own number, one agent's across the install. " \
      "Shared only where a workspace sets none of its own.",
    mail: "One mail domain and one SMTP and IMAP account deliver every agent's email; each agent has its own address. " \
      "A workspace may have its own domain, server and catch-all box (Workspace::MailDomain), which the install's operator sets; " \
      "an address's name is unique across the install, so it names one agent whatever its domain. " \
      "Shared only where a workspace sets none of its own.",
    caldav: "One CalDAV server; each agent its own account on it. Removed in step 2: per-workspace secrets and identities.",
    connectors: "The OAuth apps (the Google client) every workspace's connectors sign in through, the gallery, " \
      "and the internal hosts the operator lets a workspace's office connector address name. " \
      "Removed in step 2: per-workspace secrets and identities.",
    link: "One Link app for payments; each person connects their own wallet. " \
      "Removed in step 2: per-workspace secrets and identities.",
    access: "One list of who may sign in, who administers, and the install's owner; what asks a person first trusts only " \
      "it, never a workspace's invitation. Removed in step 2: per-workspace secrets and identities."
  }.freeze

  # Install-wide settings that hold nothing of any workspace's: where the app
  # is, how people sign in, and where errors, traces and notices go.
  INSTALL_PLUMBING = {
    app: "The app's address, name, colour and starter agent, and tool restrictions applied to every workspace. " \
      "A workspace may go by its own name, colour and link host (Brand), shown and linked only for its own people: " \
      "CrossWorkspaceLeakTest finds B's name on none of A's pages.",
    oidc: "The sign-in provider every person signs in through.",
    glitchtip: "Where errors are reported, scrubbed of content.",
    analytics: "Rybbit's site: page views, masked.",
    web_push: "The install's Web Push keys; each notice goes to its own person's browsers.",
    apns: "The install's Apple push key; each notice goes to its own person's phones.",
    turnstile_preview: "A dedicated release-vault reader for one configured preview project, hostname, workspace and owner.",
    voice: "One signed voice endpoint binds to one operator-selected agent; no workspace can read the settings or receipts.",
    forge: "A local socket restricted to one workspace and its one configured agent; it is not shared."
  }.freeze

  def build_world
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @carol = create_user(name: "Carol")
    @dave = create_user(name: "Dave")
    @carol.update!(name: "Carol #{MARK}-owner")
    @dave.update!(name: "Dave #{MARK}-member")

    @a = Workspace.create!(name: "Acorn")
    @a.memberships.create!(user: @alice, role: "owner")
    @bobs_membership = @a.memberships.create!(user: @bob, role: "member")
    @b = Workspace.create!(name: "Birch #{MARK}")
    @b.memberships.create!(user: @carol, role: "owner")
    @daves_membership = @b.memberships.create!(user: @dave, role: "member")

    build_a
    build_b
  end

  # Bob's own, in A: the parents a nested route is asked under, with B's record at its end.
  def build_a
    @a_agent = @alice.start_agent("Ada", workspace: @a)
    @a_agent.update!(capabilities: @a_agent.capabilities | %w[ subagents ], tool_names: Tool::Catalog.names)
    @a_conversation = create_conversation(@a_agent, durable_id: "a-1")
    @a_conversation.messages.create!(role: "assistant", content: "Hello from A.", entry_id: 1, entry_key: "a-e-1")
    @a_connector = @a.mcp_servers.create!(user: @alice, name: "alook", url: "https://a.example.com/mcp", refreshed_at: Time.current,
      tools: [ { "name" => "lookup", "description" => "Look something up in A.", "annotations" => { "readOnlyHint" => true } } ])
    @a_skill = @a_agent.skills.create!(name: "a-skill", description: "A's skill.", body: "Do A things.")
    @a_prompt = @a_agent.prompts.create!(name: "a-prompt", body: "A")
    @a_routine = @a_agent.routines.create!(schedule: "every day at 8am", prompt: "A")
    @a_permission = @a_agent.permissions.create!(tool_name: "forget_note", granted_by: @alice)
    @a_document = @a_agent.documents.create!(title: "A doc").tap { it.revise("A body", by: "agent") }
    @a_invocation = @a_conversation.invocations.create!(task_id: "7", call_id: "toolu_a", tool_name: "ask_person",
      arguments: { "question" => "A?" }, digest: "a", state: "awaiting_person", expires_at: 1.hour.from_now)
    @a_helper = @a_conversation.helpers.create!(call_id: "toolu_ah", task: "A helper")
    @a_held_email = @a_conversation.held_emails.create!(invocation: @a_invocation, send_at: 1.hour.from_now)
    @a_screen_pass, = ScreenPass.issue!(@a_conversation, by: @alice)
    @a_sign_in_link, = SignInLink.issue!(@a_invocation, entry_id: "a-entry", name: "A bank")
    @a_run = @a_conversation.workflows.create!(name: "A flow", kind: "fan_out", steps: [ { "task" => "A" } ]).start(call_id: "toolu_aw")
    @a_concourse = @a_agent.concourse_agents.create!(organization: "anet", handle: "anet/ada", client_id: "a-client", client_secret: "a-secret")
    @a_invitation = @a.invitations.create!(email: "frank@example.com", inviter: @alice)
    @a_route = @a.contact_routes.create!(contact: "grace@example.com", agent: @a_agent)
    @a.change_instructions("Be kind in A.", by: @alice)
    @a_proposal = @a.proposals.create!(proposed_by: @bob, instructions: "Be brief in A.")
    @a_push = @bob.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/fcm/send/a-bob", p256dh_key: "a-key", auth_key: "a-auth")
    @a_watch = @bob.watches.create!(name: "Bob's Watch")
    @a_share = @bob.shares.create!(text: "From Bob's phone")
    @a_mailbox = @a_agent.mail_accounts.create!(read_only: true, address: "old-a@example.com", imap_host: "imap.a.example.com", vault_entry: "A old")
    @a_read_only_calendar = @a_agent.calendar_servers.create!(read_only: true, url: "https://dav.a.example.com/calendars/old/", vault_entry: "A old")
  end

  def build_b
    @b_agent = @carol.start_agent("Bea #{MARK}", workspace: @b, purpose: "#{MARK}-instructions")
    @b_conversation = create_conversation(@b_agent, durable_id: "b-1")
    @b_conversation.update!(title: "#{MARK}-title")
    @b_message = @b_conversation.messages.create!(role: "user", content: "#{MARK}-asked", entry_id: 1, entry_key: "b-e-1", author: @dave)
    @b_conversation.messages.create!(role: "assistant", content: "#{MARK}-answered", entry_id: 2, entry_key: "b-e-2")
    @b_card = @b_conversation.invocations.create!(task_id: "7", call_id: "toolu_b", tool_name: "ask_person",
      arguments: { "question" => "#{MARK}-card", "wait" => false }, digest: "b", state: "awaiting_person", expires_at: 1.hour.from_now,
      handed_back_at: 1.minute.ago)
    paying = @b_conversation.invocations.create!(task_id: "7", call_id: "toolu_bp", tool_name: "pay_by_card",
      arguments: { "payee" => "#{MARK}-payee" }, digest: "bp", state: "awaiting_person", expires_at: 1.hour.from_now)
    @b_payment = paying.create_payment_request!(amount: 1_200, currency: "usd", payee: "#{MARK}-payee",
      checkout_url: "https://shop.example/#{MARK}", reason: "#{MARK}-reason")
    @b_document = @b_agent.documents.create!(title: "#{MARK}-doc").tap { it.revise("#{MARK}-doc-body", by: "agent") }
    @b_version = @b_document.versions.last
    @b_upload = Upload.store(@b_conversation, task_id: "7", call_id: "toolu_bu", path: "/home/agent/#{MARK}.txt",
      bytes: "#{MARK}-upload", each: 1.megabyte, total: 2.megabytes)
    @b_note = @b_agent.notes.create!(key: "#{MARK}-note", body: "#{MARK}-note-body")
    @b_routine = @b_agent.routines.create!(schedule: "every day at 9am", prompt: "#{MARK}-routine")
    @b_helper = @b_conversation.helpers.create!(call_id: "toolu_bh", task: "#{MARK}-helper")
    @b_held_email = @b_conversation.held_emails.create!(invocation: @b_card, send_at: 1.hour.from_now)
    @b_screen_pass, = ScreenPass.issue!(@b_conversation, by: @carol)
    @b_sign_in_link, = SignInLink.issue!(@b_card, entry_id: "b-entry", name: "#{MARK}-bank")
    @b_run = @b_conversation.workflows.create!(name: "#{MARK}-flow", kind: "fan_out", steps: [ { "task" => "#{MARK}-step" } ]).start(call_id: "toolu_bw")
    @b_computer = @b_agent.computer || @b_agent.create_computer!(name: "bea")
    @b_connector = @b.mcp_servers.create!(user: @carol, name: "bvault", url: "https://#{MARK}.example.com/mcp", refreshed_at: Time.current,
      tools: [ { "name" => "lookup", "description" => "#{MARK}-tool: look something up.", "annotations" => { "readOnlyHint" => true } } ])
    @b_thread_connector = @b.mcp_servers.create!(user: @dave, conversation: @b_conversation, name: "bthread",
      url: "https://#{MARK}-thread.example.com/mcp")
    @b_core = @b_agent.core_connectors.create!(mcp_server: @b_connector)
    @b_skill = @b_agent.skills.create!(name: "#{MARK}-skill", description: "#{MARK}-skill-description", body: "#{MARK}-skill-body")
    @b_prompt = @b_agent.prompts.create!(name: "#{MARK}-prompt", body: "#{MARK}-prompt-body")
    @b_permission = @b_agent.permissions.create!(tool_name: "send_email", recipient: "#{MARK}@example.com", granted_by: @carol)
    @b_concourse = @b_agent.concourse_agents.create!(organization: "bnet", handle: "bnet/bea", client_id: "#{MARK}-client", client_secret: "#{MARK}-secret")
    @b_peer_task = @b_conversation.peer_tasks.create!(task_id: "#{MARK}-task", peer: "bnet/friend", direction: "inbound",
      state: "TASK_STATE_SUBMITTED", concourse_agent: @b_concourse)
    @b_bot = @b_agent.create_campfire_bot!(bot_key: "9-#{MARK}")
    @b_room = @b.campfire_rooms.create!(room_id: 99)
    @b.update!(concourse_home: "bhome", campfire_url: "https://#{MARK}.campfire.example.com", campfire_vault_entry: "#{MARK}-campfire",
      voipms_vault_entry: "#{MARK}-voipms",
      app_name: "#{MARK}-brand", accent_hue: 77)
    @b_telegram = @b_agent.create_telegram_bot!(vault_entry: "#{MARK}-bot", username: "#{MARK}_bot", chats: { "-100" => "#{MARK}-group" })
    @b_telegram_message = @b_telegram.messages.create!(chat_id: -100, message_id: 1, sender: "#{MARK}-sender", text: "#{MARK}-post", sent_at: Time.current)
    @b_device = @carol.push_devices.create!(token: "b" * 64)
    @b_push = @carol.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/fcm/send/#{MARK}", p256dh_key: "b-key", auth_key: "b-auth")
    @b_watch = @carol.watches.create!(name: "#{MARK}-watch")
    @b_share = @dave.shares.create!(text: "#{MARK}-share")
    @b_share.files.attach(io: StringIO.new("#{MARK}-picture"), filename: "picture.txt", content_type: "text/plain")
    @b_invitation = @b.invitations.create!(email: "erin@example.com", inviter: @carol)
    @b_route = @b.contact_routes.create!(contact: "#{MARK}@example.net", agent: @b_agent)
    @daves_membership.update!(sole_contact: @b_agent, phone_number: "4165550142")
    @b_revision = @b.change_instructions("#{MARK}-shared-instructions", by: @carol, proposed_by: @b_agent)
    @b_proposal = @b.proposals.create!(proposed_by: @dave, instructions: "#{MARK}-proposal")
    @b_agent.update!(paused_at: 1.minute.ago)
    @b_held = @b_conversation.submissions.create!(request_id: "#{MARK}-held", input_digest: "d", payload_digest: "d",
      definition_digest: "d", payload: "#{MARK}-held-message")
    @b_mail_domain = @b.create_mail_domain!(domain: "#{MARK}.example.net", smtp_host: "mail.#{MARK}.example.net", vault_entry: "#{MARK}-mail")
    @b_mailbox = @b_agent.mail_accounts.create!(read_only: true, address: "#{MARK}@example.com", imap_host: "imap.#{MARK}.example.com", vault_entry: "#{MARK}-old")
    @b_read_only_calendar = @b_agent.calendar_servers.create!(read_only: true, url: "https://dav.#{MARK}.example.com/calendars/old/", vault_entry: "#{MARK}-old")
    @b.update!(payer: @b)
    @b_usage = @b.model_usages.create!(agent: @b_agent, agent_name: @b_agent.name, conversation: @b_conversation, payer: @b,
      model: "anthropic/claude-#{MARK}-5", input: 7_777, output: 3, total_tokens: 7_780, cost: 0.5)
  end

  # Every B record, and how many each of B's things holds: whatever Bob does,
  # this reads the same after.
  def b_state
    records = [ @b, @b_agent, @b_conversation, @b_message, @b_card, @b_payment, @b_document, @b_version, @b_upload, @b_note,
      @b_routine, @b_helper, @b_run, @b_computer, @b_connector, @b_thread_connector, @b_core, @b_skill, @b_prompt, @b_permission,
      @b_concourse, @b_peer_task, @b_bot, @b_telegram, @b_telegram_message, @b_room, @b_device, @b_push, @b_watch, @b_share, @b_invitation, @b_held,
      @b_mailbox, @b_mail_domain, @b_read_only_calendar, @b_sign_in_link, @b_usage, @b_revision, @b_proposal, @daves_membership, @b_route, @carol, @dave ]
    rows = records.to_h { [ "#{it.class.name}##{it.id}", it.class.unscoped.find_by(id: it.id)&.attributes ] }
    counts = {
      workspace: %i[ memberships invitations revisions proposals contact_routes agents mcp_servers install_connectors conversations messages invocations helpers workflow_runs model_usages campfire_rooms ],
      agent: %i[ notes documents skills prompts routines permissions concourse_agents core_connectors campfire_bot telegram_bot revisions mail_accounts calendar_servers ],
      conversation: %i[ submissions uploads peer_tasks mcp_servers workflows sign_in_links ],
      telegram_bot: %i[ messages ],
      carol: %i[ shares push_devices push_subscriptions watches ],
      dave: %i[ shares push_devices push_subscriptions watches ]
    }.flat_map do |owner, names|
      record = { workspace: @b, agent: @b_agent, conversation: @b_conversation, telegram_bot: @b_telegram, carol: @carol, dave: @dave }.fetch(owner)
      names.map { [ "#{owner}.#{it}", Array(record.class.unscoped.find(record.id).public_send(it)).size ] }
    end.to_h
    rows.merge(counts, "version bodies" => @b_document.versions.pluck(:body), "share files" => @b_share.reload.files.count)
  end
end

# Every route that takes a parameter, as Bob in A asking for B's record.
class CrossWorkspaceRoutesTest < ActionDispatch::IntegrationTest
  include CrossWorkspaceWorld

  # Routes that take a parameter but are not a signed-in person's way to a
  # workspace's record, each with why it is not asked here.
  NOT_ASKED = {
    %r{\Asidecar/} => "The sidecar's private callbacks: no session, their own bearer token, and only from inside the host " \
      "(test/controllers/sidecar/). Out of scope here.",
    %r{\Acampfire_webhooks\z} => "Campfire's webhook: the bot's secret token admits it, never a session.",
    %r{\Atelegram_webhooks\z} => "Telegram's webhook: the bot's secret in Telegram's header admits it, never a session.",
    %r{\Aconcourse_pushes\z} => "Concourse's doorbell: the agent's push token admits it, never a session.",
    %r{\Ascreen_passes\z} => "A one-time link to one screen: its own token admits it, never a session (screen_passes_test.rb).",
    %r{\Asign_in_links(/|\z)} => "A one-time link to fill one empty vault entry: its own token admits it, never a session (sign_in_links_test.rb).",
    %r{\Aicons\z} => "Fixed icon variants, no record.",
    %r{\Aconfigurations\z} => "The phone app's fixed path configurations, no record.",
    %r{\Aaction_mailbox/} => "Inbound mail's ingress: its own password, no session.",
    %r{\Arails/conductor/} => "Action Mailbox's development console: not routed in production.",
    %r{\Aactive_storage/disk\z} => "The disk service's own short-lived signed tokens, minted by a blob route asked below.",
    %r{\Aactive_storage/(blobs|representations)/} => "A picture's signed link: asked in \"a picture of B's, by its link\".",
    %r{\Aactive_storage/direct_uploads\z} => "Uploads a new blob; names none.",
    %r{\Aturbo/} => "Turbo's history redirects, no record.",
    %r{\Asubscriptions(/|\z)} => "The install's model subscriptions: SHARED_ACROSS_WORKSPACES[:pi_durable]."
  }.freeze

  setup do
    build_world
    @a_gmail = gmail_for(@a, @alice, "a_gmail")
    @b_gmail = gmail_for(@b, @carol, "#{MARK}_gmail")
    @a_gmail_grant = @a_gmail.gmail_reply_grants.create!(agent: @a_agent, address: "pat@example.net")
    @b_gmail_grant = @b_gmail.gmail_reply_grants.create!(agent: @b_agent, address: "#{MARK}@example.net")
    @a_setup = @a.agent_setups.build(approved_by: @alice, operator: @alice, manager_id: @a_agent.id,
      request_id: SecureRandom.uuid, name: "New A report", instructions: "Test A", authorization: "Setup A only").record!
    @b_setup = @b.agent_setups.build(approved_by: @carol, operator: @carol, manager_id: @b_agent.id,
      request_id: SecureRandom.uuid, name: "New B report", instructions: MARK, authorization: MARK).record!
    # Every outside call, the sidecar's too, fails as an unreachable service would.
    stub_request(:any, /.*/).to_return(status: 503, body: "{}")
    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")
    get workspace_path(@a)
    assert_equal @a.id, session[:workspace_id]
    get conversation_path(@a_conversation)
    assert_response :success, "Bob reaches his own workspace's thread"
  end
  teardown { remove_sidecar_settings }

  test "every route with a parameter finds nothing of B, with B's record or under Bob's own" do
    routes = asked_routes
    assert_operator routes.size, :>, 100, "every route with a parameter is asked"
    before = b_state

    requests = routes.flat_map do |verb, spec|
      [ [ verb, spec, path_for(spec, :b) ], ([ verb, spec, path_for(spec, :mixed) ] if nested_record?(spec)) ].compact
    end
    reached = requests.filter_map { |verb, spec, path| ask(verb, path, spec) }

    assert_empty reached, "#{reached.size} of #{requests.size} requests reached B:\n#{reached.join("\n")}"
    assert_equal before, b_state, "B is unchanged"
  end

  # A record named in a form or a query rather than the path: B's ids in
  # every field that names one, on each of Bob's own routes.
  test "B's ids in a form or a query, on Bob's own routes, reach nothing of B" do
    before = b_state
    shown = asked_routes.reject { |verb, _| verb == "DELETE" }.filter_map do |verb, spec|
      path = path_for(spec, :a)
      begin
        public_send(verb.downcase, path, params: references)
      rescue StandardError
        next # an action that failed on Bob's own record told nothing
      end
      "#{verb} #{path} (#{response.status})" if response.body.include?(MARK) || response.location.to_s.include?(MARK)
    end

    assert_empty shown, "B's content was shown:\n#{shown.join("\n")}"
    assert_equal before, b_state, "B is unchanged"
  end

  test "no page, list or JSON without a parameter shows anything of B" do
    gets = Rails.application.routes.routes.filter_map do |route|
      spec = route.path.spec.to_s.delete_suffix("(.:format)")
      spec if route.verb == "GET" && !spec.include?(":") && !spec.include?("*") && route.defaults[:controller] && !not_asked(route)
    end.uniq
    assert_operator gets.size, :>, 10

    shown = gets.product([ {}, { "Accept" => "application/json" } ]).filter_map do |path, headers|
      get path, headers: headers
      "GET #{path} #{headers.values.join} (#{response.status})" if response.body.include?(MARK)
    rescue StandardError
      next # a page with no JSON (or no page) showed nothing
    end
    assert_empty shown, "B's content was shown:\n#{shown.join("\n")}"
  end

  test "the Workspaces overview shows A's agents, cards, errors and held rooms, never B's, though B's are stuck, failing and held" do
    @a.campfire_rooms.create!(room_id: 5, held_at: 10.minutes.ago)
    @b_bot.update!(rooms: { "99" => "#{MARK}-room" })
    @b_room.update!(held_at: 5.minutes.ago)
    @b_conversation.update!(execution_status: "error", failure: "#{MARK}-failure")
    @b_card.update_columns(created_at: 2.hours.ago)
    @b_conversation.invocations.create!(task_id: "7", call_id: "toolu_bf", tool_name: "send_email", arguments: {}, digest: "bf",
      state: "failed", error: "#{MARK}-failed-call")

    get workspaces_overview_path
    assert_response :success
    assert_select "a[href=?]", approval_path(@a_invocation), text: /A\?/
    assert_select "a[href=?]", conversation_path(@a_conversation), text: /Ada/
    assert_select "a[href=?]", workspace_path(@a, anchor: "campfire"), text: /Room 5/
    assert_not_includes response.body, MARK
    assert_not_includes response.body, "Room 99"
    [ approval_path(@b_card), workspace_path(@b, anchor: "campfire"), *b_paths ].each { assert_not_includes response.body, it }

    sign_in_via_ajent(subject: "sub-dave", email: "dave@example.com", name: "Dave")
    get workspaces_overview_path
    assert_select "a[href=?]", approval_path(@b_card), text: /#{MARK}-card.*Stuck/m
    assert_includes response.body, "#{MARK}-failed-call", "B's member sees it"
    assert_select "a[href=?]", workspace_path(@b, anchor: "campfire"), text: /#{MARK}-room/
  end

  test "A's Usage page shows A's own usage, never B's, even B's billed to A" do
    @a.model_usages.create!(agent: @a_agent, agent_name: @a_agent.name, model: "anthropic/claude-opus-5-5", input: 11, total_tokens: 11)
    @b_usage.update!(payer: @a)

    get workspace_usage_path(@a)
    assert_response :success
    assert_select "li", text: /Ada.*11 in/m
    assert_not_includes response.body, MARK
    assert_not_includes response.body, "7,777"
  end

  test "Bob cannot choose B to work in, and stays in A" do
    get workspace_path(@b)
    assert_response :not_found
    assert_equal @a.id, session[:workspace_id]

    get root_path
    assert_select "head style[data-turbo-track=dynamic]", text: /--accent-hue: 255;/, message: "A's pages in the install's colour, never B's own"
  end

  test "a picture of B's, by its link, is not Bob's to fetch" do
    Rails.application.eager_load!
    attached = ApplicationRecord.descendants.select { it.reflect_on_all_attachments.any? }.map(&:name).sort
    assert_equal %w[ Conversation::Submission Invocation Message Share Upload ], attached, "A record with attachments says who reaches them in ReachableBlobs"

    file = @b_share.files.sole
    [ rails_blob_path(file, disposition: :attachment), rails_storage_proxy_path(file) ].each do |path|
      get path
      assert_response :not_found, path
      assert_not_includes response.body, MARK
    end

    sign_in_via_ajent(subject: "sub-dave", email: "dave@example.com", name: "Dave")
    get rails_storage_proxy_path(file)
    assert_response :success, "Dave, whose phone shared it, fetches it"
    assert_equal "#{MARK}-picture", response.body
  end

  test "a picture in a shared workspace's thread is every member's, and nobody else's" do
    @b_message.images.attach(io: StringIO.new("#{MARK}-thread-picture"), filename: "thread.txt", content_type: "text/plain")
    carols_own = @carol.personal_workspace.agents.sole.conversation
    personal = carols_own.messages.create!(role: "user", content: "Carol's own", entry_id: 1, entry_key: "c-e-1", author: @carol)
    personal.images.attach(io: StringIO.new("#{MARK}-personal-picture"), filename: "own.txt", content_type: "text/plain")
    in_b, carols_alone = @b_message.images.sole, personal.images.sole

    get rails_storage_proxy_path(in_b)
    assert_response :not_found, "Bob, in no workspace with it, does not fetch B's picture"

    sign_in_via_ajent(subject: "sub-dave", email: "dave@example.com", name: "Dave")
    @b_message.update!(author: @carol)
    get rails_storage_proxy_path(in_b)
    assert_response :success, "Dave, a member of B, fetches a picture in Carol's agent's thread there"
    assert_equal "#{MARK}-thread-picture", response.body
    get rails_storage_proxy_path(carols_alone)
    assert_response :not_found, "Carol's personal workspace is not Dave's"
    assert_not_includes response.body, MARK
  end

  test "a file attached in B's thread is reached only through that thread" do
    @b_message.files.attach(io: StringIO.new("#{MARK}-thread-file"), filename: "plan.docx", content_type: "application/octet-stream")
    file = @b_message.files.sole

    [ rails_blob_path(file, disposition: :attachment), rails_storage_proxy_path(file) ].each do |path|
      get path
      assert_response :not_found, "Bob, in no workspace with B's thread, does not fetch its file: #{path}"
      assert_not_includes response.body, MARK
    end

    sign_in_via_ajent(subject: "sub-dave", email: "dave@example.com", name: "Dave")
    get rails_storage_proxy_path(file)
    assert_response :success, "Dave, a member of B, fetches it"
    assert_equal "#{MARK}-thread-file", response.body
  end

  private
    def gmail_for(workspace, user, name)
      workspace.mcp_servers.create!(user: user, name: name, **McpServer.gallery_attributes("gmail"), tools: [],
        refreshed_at: Time.current, oauth_tokens: { "access_token" => "sample-token" })
    end

    def b_state
      super.merge("Gmail connector" => @b_gmail.reload.attributes,
        "Gmail reply grants" => @b_gmail.gmail_reply_grants.order(:id).map(&:attributes))
    end

    def asked_routes
      Rails.application.routes.routes.filter_map do |route|
        spec = route.path.spec.to_s.delete_suffix("(.:format)")
        next unless spec.include?(":") && route.defaults[:controller] && !not_asked(route)
        route.verb.split("|").map { [ it, spec ] }
      end.flatten(1).uniq
    end

    # Asked under Bob's own parent too, when its last parameter is a record of
    # the app's. A queued message's id is the sidecar's, which keeps it under
    # the thread's own conversation: under Bob's thread it names only his.
    def nested_record?(spec) = spec.scan(/:\w+/).size > 1 && !spec.include?("/queued_messages/")

    def not_asked(route) = NOT_ASKED.keys.find { it.match?(route.defaults[:controller].to_s) }

    # Not found, or a redirect that names nothing of B; MARK in nothing.
    def ask(verb, path, spec)
      public_send(verb.downcase, path, params: (references unless verb == "GET"))
      location = response.location.to_s
      revealed = response.body.include?(MARK) || location.include?(MARK) || b_paths.any? { location.include?(it) }
      "#{verb} #{path} [#{spec}] (#{response.status} #{location})" if revealed || !(response.not_found? || response.redirect?)
    rescue StandardError => error # an action that ran far enough to fail found the record
      "#{verb} #{path} [#{spec}] (#{error.class}: #{error.message.first(200)})"
    end

    def b_paths
      [ "/agents/#{@b_agent.id}", "/conversations/#{@b_conversation.id}", "/connectors/#{@b_connector.id}", "/connectors/#{@b_gmail.id}", "/workspaces/#{@b.id}" ]
    end

    # A path for the route: every parameter B's (:b), Bob's own (:a), or
    # Bob's own with B's record last (:mixed).
    def path_for(spec, side)
      names = spec.scan(/:(\w+)/).flatten
      spec.gsub(/:(\w+)/) do
        name = Regexp.last_match(1)
        owner = side == :mixed ? (name == names.last ? :b : :a) : side
        record_for(spec, name, owner).to_s
      end
    end

    # A parameter is the record named by the path segment it follows
    # (/skills/:id) or by its own name (:skill_id). A new one fails here until
    # RECORDS says which record it is.
    def record_for(spec, name, owner)
      segment = name == "id" ? spec[%r{/([a-z_]+)/:id(?:/|\z)}, 1] : name.delete_suffix("_id").pluralize
      segment = "#{spec[%r{\A/([a-z_]+)/}, 1]}/#{segment}" if %w[ helpers subscriptions ].include?(segment) && spec.match?(%r{\A/(conversations|push)/})
      segment = "#{spec[%r{\A/([a-z_]+)/}, 1]}/#{segment}" if segment == "instruction_revisions"
      segment = "gmail_connectors" if segment == "connectors" && spec.include?("/gmail_reply_grants")
      records = records_by_segment.fetch(segment) { flunk "#{spec}: which record is :#{name}? Add #{segment.inspect} to records_by_segment" }
      value = records.fetch(owner)
      value.respond_to?(:to_param) ? value.to_param : value
    end

    def records_by_segment
      @records_by_segment ||= {
        "workspaces" => { a: @a, b: @b },
        "agent_setups" => { a: @a_setup, b: @b_setup },
        "install_connectors" => { a: "wiki", b: "wiki" },
        "memberships" => { a: @bobs_membership, b: @daves_membership },
        "invitations" => { a: @a_invitation, b: @b_invitation },
        "contact_routes" => { a: @a_route, b: @b_route },
        "proposals" => { a: @a_proposal, b: @b_proposal },
        "agents" => { a: @a_agent, b: @b_agent },
        "agents/instruction_revisions" => { a: @a_agent.revisions.last!, b: @b_agent.revisions.last! },
        "workspaces/instruction_revisions" => { a: @a.revisions.first!, b: @b.revisions.first! },
        "mailboxes" => { a: @a_mailbox, b: @b_mailbox },
        "read_only_calendars" => { a: @a_read_only_calendar, b: @b_read_only_calendar },
        "core_connectors" => { a: @a_connector, b: @b_connector },
        "skills" => { a: @a_skill, b: @b_skill },
        "prompts" => { a: @a_prompt, b: @b_prompt },
        "routines" => { a: @a_routine, b: @b_routine },
        "permissions" => { a: @a_permission, b: @b_permission },
        "concourse_agents" => { a: @a_concourse, b: @b_concourse },
        "tools" => { a: "mcp__alook__lookup", b: "mcp__bvault__lookup" },
        "names" => { a: "mcp__alook__lookup", b: "mcp__bvault__lookup" },
        "conversations" => { a: @a_conversation, b: @b_conversation },
        "documents" => { a: @a_document, b: @b_document },
        "deleted_documents" => { a: @a_document, b: @b_document },
        "invocations" => { a: @a_invocation, b: @b_card },
        "approvals" => { a: @a_invocation, b: @b_card },
        "conversations/helpers" => { a: @a_helper, b: @b_helper },
        "workflow_runs" => { a: @a_run, b: @b_run },
        "held_emails" => { a: @a_held_email, b: @b_held_email },
        "screen_passes" => { a: @a_screen_pass, b: @b_screen_pass },
        "sign_in_links" => { a: @a_sign_in_link, b: @b_sign_in_link },
        # Kept in the sidecar under the thread's own conversation: B's thread is asked for by its id.
        "queued_messages" => { a: "q-1", b: "q-b" },
        "held_messages" => { a: "0", b: @b_held },
        "connectors" => { a: @a_connector, b: @b_connector },
        "gmail_connectors" => { a: @a_gmail, b: @b_gmail },
        "gmail_reply_grants" => { a: @a_gmail_grant, b: @b_gmail_grant },
        "shares" => { a: @a_share, b: @b_share },
        "push/subscriptions" => { a: @a_push, b: @b_push },
        "watches" => { a: @a_watch, b: @b_watch }
      }
    end

    # Every field a form or query names a record by, filled with B's, beside
    # what each form needs to get as far as its record. Ids only, never MARK:
    # the test's error pages show the request's own parameters.
    def references
      @references ||= {
        conversation_id: @b_conversation.id, document_id: @b_document.id, version_id: @b_version.id, share_id: @b_share.id,
        share: @b_share.id, from: @b_message.id, invocation_id: @b_card.id, helper_id: @b_helper.call_id, version: "1",
        request_id: "leak-1", when_busy: "followUp", to: "up", on: "0", decision: "deny", text: "x", content: "x",
        tool: "send_email", setting: "asks_every",
        confirm_name: "Ada", digest: "x", sha: "x", source: "https://github.com/acme/skills", fingerprints: [ "x" ],
        agent: { title: "x", instructions: "x", phone_number: "", caldav_username: "", caldav_password: "",
          linked_calendar_server: "", linked_calendar: "", linked_calendar_entry: "", mail_to_agent_id: @b_agent.id },
        connector: { enabled: "0", name: "leak", url: "https://leak.example.com/mcp", conversation_id: @b_conversation.id },
        gmail_reply_grant: { agent_id: @b_agent.id, address: "leak@example.net" },
        routine: { paused: "1" }, prompt: { name: "leak", body: "x" }, skill: { name: "leak", description: "x", markdown: "x" },
        computer: { notes_file: "0" }, campfire_bot: { bot_key: "1-x" }, telegram_bot: { vault_entry: "x" }, document: { body: "x" }, workspace: { name: "x", payer_id: @b.id, instructions: "x", approval_policy: "everything" }, proposal: { instructions: "x" },
        invitation: { email: "leak@example.com" }, contact_route: { contact: "leak@example.com", agent_id: @b_agent.id },
        membership: { sole_contact_id: @b_agent.id, phone_number: "" }, answer: { text: "x" }, sign_in: { username: "x", password: "x" },
        user: { name: "Bob" }, push_subscription: { endpoint: "https://fcm.googleapis.com/fcm/send/leak", p256dh_key: "k", auth_key: "a" }
      }
    end
end

# The live streams: a person hears a stream only of a workspace they are in,
# or their own, whichever channel they subscribe through.
class CrossWorkspaceStreamsTest < ActionCable::Channel::TestCase
  include CrossWorkspaceWorld

  setup { build_world }
  teardown do
    self.class.tests WorkspaceStreamsChannel
    remove_sidecar_settings
  end

  test "Bob hears A's streams and his own, through the workspace channel" do
    self.class.tests WorkspaceStreamsChannel
    stub_connection current_user: @bob
    [ [ @a, :conversations ], [ @a, :helpers ], @a_agent, [ @a_agent, :helpers ], @a_conversation ].each do |streamables|
      subscribe signed_stream_name: signed(streamables)
      assert subscription.confirmed?, streamables.inspect
    end
  end

  test "Bob is refused every stream of B's and of its people, through either channel" do
    [ WorkspaceStreamsChannel, Turbo::StreamsChannel ].each do |channel|
      self.class.tests channel
      stub_connection current_user: @bob
      [ [ @b, :conversations ], [ @b, :helpers ], @b_agent, [ @b_agent, :helpers ], @b_conversation,
        [ @carol, :connectors ], [ @carol, :badge ], [ @dave, :badge ] ].each do |streamables|
        subscribe signed_stream_name: signed(streamables)
        assert subscription.rejected?, "#{channel} let Bob hear #{streamables.inspect}"
      end
    end
  end

  private
    def signed(streamables) = Turbo::StreamsChannel.signed_stream_name(streamables)
end

# Every tool, called by A's agent through the ledger as the sidecar calls
# it, with B's records for every argument that names one.
class CrossWorkspaceToolsTest < ActiveSupport::TestCase
  include CrossWorkspaceWorld

  # Tools whose arguments name no record of the app's, each with why.
  NAMES_NO_RECORD = {
    "Tool::AddRoutine" => "Makes a routine of its own agent's.",
    "Tool::AskPerson" => "Asks a person on its own thread.",
    "Tool::RequestPhoneLocation" => "Names no record. The owner of its own invocation shares from a signed-in phone (phone_location_test.rb).",
    "Tool::ChangeYourself" => "Changes its own agent, or proposes its own workspace's shared instructions.",
    "Tool::ListRoutines" => "Lists its own agent's routines.",
    "Tool::WaitingMessages" => "Lists and takes in what waits in its own conversation; ids are the sidecar's, never a record.",
    "Tool::MakeAgent" => "Makes a new agent; names none.",
    "Tool::FileUnder" => "Labels its own thread; the label is its own text, not a record.",
    "Tool::JoinConcourse" => "A link to join; names nothing.",
    "Tool::RunWorkflow" => "Starts a new workflow of its own thread's.",
    "Tool::PayByCard" => "Asks to pay a checkout address; names no record.",
    "Tool::SendEmail" => "Sends from its own address; from must be one of its own (Agent#sending_addresses; agent_mail_account_test.rb " \
      "refuses any other), in_reply_to is a mail Message-ID and attachments are paths on its own computer.",
    "Tool::SaveDraft" => "Saves to its own agent's sending mail account (Agent#mail_account); in_reply_to is a mail Message-ID.",
    "Tool::ReadOwnMail" => "Reads its own agent's sending mail accounts only (Agent#mail_accounts, never one read only; read_own_mail_test.rb " \
      "refuses another's); folder, message_id and thread are mail names, not records.",
    "Tool::ChangeOwnMail" => "Changes its own agent's sending mail accounts only, as read_own_mail (change_own_mail_test.rb refuses " \
      "another's); folder, uids, message_id, to and label are mail names, not records.",
    "Tool::SendText" => "Sends from its own number.",
    "Tool::PlaceCall" => "Rings a phone number, for the install's one voice agent; names no record.",
    "Tool::PhoneNumberSettings" => "Reads numbers on its own workspace's voip.ms account (or the install's); the number is a DID, not an app record.",
    "Tool::ChangePhoneNumberSettings" => "Changes its own number, on its workspace's voip.ms account (or the install's).",
    "Tool::CalendarLists" => "Its own CalDAV account (SHARED_ACROSS_WORKSPACES[:caldav] is only the server).",
    "Tool::CalendarFind" => "Its own CalDAV account.",
    "Tool::CalendarSaveEvent" => "Its own CalDAV account; id is a calendar event's.",
    "Tool::CalendarSaveTask" => "Its own CalDAV account; id is a calendar task's.",
    "Tool::CalendarDelete" => "Its own CalDAV account; id is a calendar entry's.",
    "Tool::ImessageChats" => "The install's one iMessage account: SHARED_ACROSS_WORKSPACES[:bluebubbles].",
    "Tool::ImessageHistory" => "The install's one iMessage account: SHARED_ACROSS_WORKSPACES[:bluebubbles].",
    "Tool::ImessageAttachment" => "The install's one iMessage account: SHARED_ACROSS_WORKSPACES[:bluebubbles].",
    "Tool::ImessageSend" => "The install's one iMessage account: SHARED_ACROSS_WORKSPACES[:bluebubbles].",
    "Tool::ListSavedSignIns" => "Its workspace's Passbolt user, or the install's: SHARED_ACROSS_WORKSPACES[:passbolt].",
    "Tool::SignInWithSavedPassword" => "Its workspace's Passbolt user, or the install's: SHARED_ACROSS_WORKSPACES[:passbolt].",
    "Tool::AskForSignIn" => "Its workspace's Passbolt user, or the install's: SHARED_ACROSS_WORKSPACES[:passbolt].",
    "Tool::AskOutsideForSignIn" => "Its workspace's Passbolt user, or the install's: SHARED_ACROSS_WORKSPACES[:passbolt]; its link is of its own call.",
    "Tool::CallApiWithSavedKey" => "Its workspace's Passbolt user, or the install's: SHARED_ACROSS_WORKSPACES[:passbolt].",
    "Tool::CreateTurnstilePreview" => "Only the configured preview hostname and workspace; TurnstilePreviewTest proves isolation.",
    "Tool::Forge" => "Names no app record; the persisted agent and workspace and live invocation bind it (forge_invocations_test.rb).",
    "Tool::CampfireSay" => "Posts as its own bot, on its workspace's Campfire; its relay is asked below.",
    "Tool::CampfireRooms" => "Lists its own bot's rooms, on its workspace's Campfire.",
    "Tool::CampfireHistory" => "Reads a room as its own bot, on its workspace's Campfire.",
    "Tool::CampfireMakeRoom" => "Names agents and people of its own workspace only (test/lib/campfire_test.rb).",
    "Tool::CampfireDeleteRoom" => "Deletes a room on its workspace's Campfire: SHARED_ACROSS_WORKSPACES[:campfire] where that is the install's.",
    "Tool::TelegramSend" => "Sends as its own agent's bot; chat is Telegram's id, not a record.",
    "Tool::TelegramFile" => "Saves a file its own agent's bot was sent; file is Telegram's id, not a record.",
    "Tool::TelegramMessages" => "Searches its own agent's bot's kept posts and its own sends; chat is Telegram's id or a title, not a record " \
      "(telegram_bot_test.rb and telegram_messages_test.rb: another agent's bot's chat is refused, and its sends never show, " \
      "even in a group both bots are in).",
    "Tool::ConcourseFind" => "Searches the agent's own networks, a bridge only once approved: SHARED_ACROSS_WORKSPACES[:concourse].",
    "Tool::Mcp::Call" => "A connector's tool: B's are asked by name below.",
    "Tool::Mcp::Group::Call" => "A connector's tool: B's are asked by name below.",
    "Tool::Mcp::Group::Gone" => "A connector's tool gone since: nothing to reach."
  }.freeze

  setup do
    build_world
    with_concourse = DurableAssistants::Concourse.method(:configured?)
    @restore_concourse = -> { DurableAssistants::Concourse.define_singleton_method(:configured?, with_concourse) }
    DurableAssistants::Concourse.define_singleton_method(:configured?) { true }
  end
  teardown do
    @restore_concourse&.call
    remove_sidecar_settings
  end

  test "every tool either names B's records below or says why it names none" do
    Rails.application.eager_load!
    tools = Tool.descendants.filter_map(&:name).grep(/\ATool::/).sort
    assert_equal tools, (NAMES_NO_RECORD.keys + calls.keys).sort,
      "A new tool goes in calls, with B's records for what it names, or NAMES_NO_RECORD with why"
  end

  test "A's agent reaches none of B's notes, documents, routines, helpers, tasks or skills" do
    before = b_state
    asked = calls.to_h { |klass, arguments| [ klass.constantize.tool_name, Array.wrap(arguments.call) ] }
    # What A's agent passed it may be told back (a key it named, a note it wrote); only what it did not pass is B's.
    passed = asked.values.flatten.flat_map { strings_in(it) }.uniq.sort_by { -it.length }
    assert_not_includes passed, MARK, "A whole MARK passed would hide any told back"
    reached = asked.flat_map do |name, calls|
      assert @a_conversation.reload.tool(name), "A's agent is offered #{name}"
      calls.each_with_index.filter_map do |values, index|
        outcome = call(name, values, call_id: "toolu_#{name}_#{index}")
        told = passed.reduce(outcome.to_json) { |text, string| text.gsub(string.to_json[1..-2], "") }
        "#{name} #{values.to_json} → #{outcome.to_json.first(300)}" if told.include?(MARK)
      end
    end

    assert_empty reached, "A's agent reached B:\n#{reached.join("\n")}"
    assert_equal before, b_state, "B is unchanged"
  end

  test "A's agent is offered none of B's connectors, nor B's thread's, and cannot call their tools" do
    names = (@a_conversation.tools + @a_conversation.lookup_tools).map(&:tool_name)
    assert_includes names, "mcp__alook__lookup"
    assert_empty names.grep(/bvault|bthread/)
    assert_equal [ @a_connector ], @a_conversation.connectors

    outcome = call("mcp__bvault__lookup", {})
    assert outcome[:isError], outcome.to_json
    assert_not_includes outcome.to_json, MARK

    used = call("use_tool", { "name" => "mcp__bvault__lookup", "arguments" => {} }, call_id: "toolu_use")
    assert used[:isError], used.to_json
    assert_not_includes used.to_json, MARK
  end

  test "A's agent's Campfire words reach none of B's agents, even one it names, nor its room's hold" do
    before = b_state
    bot = @a_agent.create_campfire_bot!(bot_key: "3-acorn")
    bot.update!(rooms: { "99" => "Shared room" })

    assert_equal({}, bot.relay(99, "@#{@b_agent.name}, are you there?", key: "leak-1"))
    assert_equal before, b_state, "B is unchanged: its bot heard nothing and its room's hold is its own"
    assert_not @a.campfire_rooms.exists?(room_id: 99), "nothing named, nothing passed on, nothing counted"
  end

  test "A's agent reads A's shared instructions and never B's, and its proposal changes only A's" do
    before = b_state
    prompt = @a_conversation.reload.definition[:instructions]
    assert_includes prompt, "Be kind in A."
    assert_not_includes prompt, MARK

    call("change_yourself", { "instructions" => "Be brief in A.", "scope" => "workspace" }, call_id: "toolu_rules")
    @a_conversation.invocations.find_by!(call_id: "toolu_rules").approve!(by: @alice)
    call("change_yourself", { "instructions" => "Be brief in A.", "scope" => "workspace" }, call_id: "toolu_rules")
    assert_equal "Be brief in A.", @a.reload.instructions
    assert_equal before, b_state, "B is unchanged"
  end

  test "A's owner, allowing every workspace tool A's agent asks with B's names, changes nothing of B's" do
    before = b_state
    calls.slice("Tool::RenameWorkspace", "Tool::InviteToWorkspace", "Tool::ChangeWorkspaceMember", "Tool::MoveAgent").each do |klass, arguments|
      Array.wrap(arguments.call).each_with_index do |values, index|
        call_id = "toolu_ws_#{klass.demodulize}_#{index}"
        outcome = call(klass.constantize.tool_name, values, call_id: call_id)
        if (card = @a_conversation.invocations.find_by(call_id: call_id)).awaiting_person?
          card.approve!(by: @alice)
          outcome = call(klass.constantize.tool_name, values, call_id: call_id)
        end
        assert outcome[:isError], "#{klass} #{values.to_json} → #{outcome.to_json}"
        # A name it passed may be told back; nothing else of B's.
        assert_not_includes values.values.reduce(outcome.to_json) { |text, value| text.gsub(value.to_s, "") }, MARK
      end
    end
    assert_equal before, b_state, "B is unchanged"
  end

  private
    def strings_in(value)
      case value
      when Hash then value.values.flat_map { strings_in(it) }
      when Array then value.flat_map { strings_in(it) }
      when String then [ value ]
      else []
      end
    end

    # Each tool that names a record, with B's: one or more calls' arguments.
    def calls
      {
        "Tool::ReadDocument" => -> { { "document_id" => @b_document.id } },
        "Tool::EditDocument" => -> { { "document_id" => @b_document.id, "edits" => [ { "find" => "doc-body", "replace" => "A" } ] } },
        "Tool::WriteDocument" => -> { [ { "title" => "#{MARK}-doc", "body" => "A" }, { "title" => "A", "body" => "A", "document_id" => @b_document.id } ] },
        "Tool::ListDocuments" => -> { [ {}, { "title" => "doc" } ] },
        "Tool::DeleteDocument" => -> { { "document_id" => @b_document.id } },
        "Tool::RemoveRoutine" => -> { { "id" => @b_routine.id } },
        "Tool::ForgetNote" => -> { { "key" => @b_note.key } },
        "Tool::RememberNote" => -> { { "key" => @b_note.key, "body" => "A" } },
        "Tool::ListNotes" => -> { [ { "query" => "note-body" }, { "query" => @b_note.key }, {} ] },
        "Tool::CheckHelper" => -> { { "helper" => @b_helper.call_id } },
        "Tool::CancelHelper" => -> { { "helper" => @b_helper.call_id } },
        "Tool::ReadSkill" => -> { { "name" => @b_skill.name } },
        "Tool::ConcourseGet" => -> { { "task_id" => @b_peer_task.task_id } },
        "Tool::ConcourseReply" => -> { { "task_id" => @b_peer_task.task_id, "state" => "completed", "text" => "A" } },
        "Tool::ConcourseSend" => -> { { "to" => "bnet/friend", "text" => "A", "task_id" => @b_peer_task.task_id, "network" => "bnet" } },
        "Tool::CurrentTime" => -> { { "received_since" => 1.year.ago.iso8601 } },
        "Tool::BriefReport" => -> { { "report_id" => @b_agent.id, "message" => "A" } },
        "Tool::ListWorkspaces" => -> { {} },
        "Tool::MakeWorkspace" => -> { { "name" => "Acorn too" } },
        "Tool::RenameWorkspace" => -> { { "workspace" => @b.name, "name" => "Taken" } },
        "Tool::InviteToWorkspace" => -> { { "workspace" => @b.name, "email" => "mallory@example.com" } },
        "Tool::ChangeWorkspaceMember" => -> { [ { "workspace" => @b.name, "email" => @dave.email, "change" => "remove" },
          { "workspace" => @b.name, "email" => @b_invitation.email, "change" => "remove" } ] },
        "Tool::WithdrawQuestion" => -> { { "question_id" => @b_card.id } },
        "Tool::WithdrawCard" => -> { { "card_id" => @b_card.id } },
        "Tool::MoveAgent" => -> { [ { "agent" => @b_agent.name, "to" => "Acorn" }, { "to" => @b.name } ] }
      }
    end

    def call(tool, arguments, call_id: "toolu_1")
      payload = invocation_payload(@a_conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@a_conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end

# A workspace's own vault user and install connector key are its agents'
# alone. A sets both; B sets neither, so its agents are on the install's. With
# made-up values, B's agent never runs the vault as A's user nor sends A's
# key, from the command's environment and the request's headers.
class CrossWorkspaceSecretsTest < ActiveSupport::TestCase
  include CrossWorkspaceWorld
  include PassboltTestHelper
  include VoipmsTestHelper
  include McpTestHelper

  WIKI = "http://example-wiki:3000/mcp".freeze
  A_KEY = "-----BEGIN PGP PRIVATE KEY BLOCK-----\nacorn-made-up\n-----END PGP PRIVATE KEY BLOCK-----".freeze
  A_PASS = "acorn-made-up-passphrase".freeze
  A_WIKI_KEY = "acorn-wiki-key-made-up".freeze

  setup do
    build_world
    install_fake_passbolt
    @previous = Rails.application.config.x.install_connectors
    Rails.application.config.x.install_connectors = { wiki: { url: WIKI, api_key: "install-wiki-key", tools: %w[ search ] } }
    stub_mcp_server(url: WIKI, tools: [ mcp_tool("search") ], calls: { "search" => ->(_) { { content: [ { type: "text", text: "found" } ] } } })
    @a.update!(passbolt_private_key: A_KEY, passbolt_passphrase: A_PASS)
    @a.install_connectors.create!(name: "wiki", api_key: A_WIKI_KEY)
    McpServer.turn_on(@a, "wiki")
  end
  teardown do
    Rails.application.config.x.install_connectors = @previous
    remove_fake_passbolt
    remove_sidecar_settings
  end

  test "B's agent reads the vault as the install's user, never A's, and A's agent as A's" do
    DurableAssistants::Passbolt.sign_ins(@b_agent)
    DurableAssistants::Passbolt.sign_in(@b_agent, "7f0c")
    assert_equal [ passbolt_user(PRIVATE_KEY, PASSPHRASE) ] * 2, passbolt_users

    DurableAssistants::Passbolt.sign_ins(@a_agent)
    assert_equal passbolt_user(A_KEY, A_PASS), passbolt_users.last
  end

  # Neither A nor B is the install owner's, so the install's key reaches neither (#168).
  test "B's agent has no wiki without a key of its own, never the install's or A's, and A's agent calls it with A's" do
    assert_not McpServer.turn_on(@b, "wiki").persisted?
    InstallConnectorsJob.perform_now
    assert_empty @b.mcp_servers.where(install: "wiki")

    @a.mcp_servers.find_by!(install: "wiki").call_tool("search", {}, conversation: @a_conversation)
    assert_requested :post, WIKI, headers: { "Authorization" => "Bearer #{A_WIKI_KEY}" }, at_least_times: 1
    assert_not_requested :post, WIKI, headers: { "Authorization" => "Bearer install-wiki-key" }
  end

  test "B's agent, its workspace naming no account, texts through the install's voip.ms account, never A's own, and A's agent through A's, read as A's vault user" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Acorn voip.ms", uri: "https://voip.ms")
    install_voipms_settings
    @a.update!(voipms_vault_entry: "Acorn voip.ms")
    @b.update!(voipms_vault_entry: nil)
    forms = stub_voipms

    [ @b_agent, @a_agent ].each { DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "Hi", account: it.voipms_account) }
    assert_equal [ [ "texts@example.com", "synthetic-api-password" ], [ "maya", PASSWORD ] ], forms.map { it.values_at("api_username", "api_password") }
    assert_equal [ passbolt_user(A_KEY, A_PASS) ], passbolt_users.uniq
  ensure
    remove_voipms_settings
  end
end

# What every workspace of an install shares today is exactly
# SHARED_ACROSS_WORKSPACES; step 2 gives each workspace its own.
class CrossWorkspaceSharedTest < ActiveSupport::TestCase
  test "every install-wide setting is shared on purpose, with why, or holds nothing of a workspace's" do
    groups = Rails.root.join("config/application.rb").read.scan(/config\.x\.(\w+) = config_for/).flatten.map(&:to_sym)
    shared, plumbing = CrossWorkspaceWorld::SHARED_ACROSS_WORKSPACES, CrossWorkspaceWorld::INSTALL_PLUMBING

    assert_equal groups.sort, (shared.keys + plumbing.keys).sort,
      "A new install-wide setting goes in SHARED_ACROSS_WORKSPACES, with why, or INSTALL_PLUMBING"
    assert_empty shared.keys & plumbing.keys
    shared.each { |name, why| assert_match(/(Removed in step 2: per-workspace secrets and identities|Shared only where a workspace sets none of its own)\.\z/, why, name) }
  end
end
