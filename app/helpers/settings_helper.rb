# The settings' places and their words (layouts/settings): the sidebar, an
# agent's sections, the way back up on a phone, and a status as a word.
module SettingsHelper
  # The places Settings lists, in groups: the sidebar (settings/_nav), which is
  # the phone app's Settings tab, and /settings.json, from which a build
  # reading ios_v2 draws its own.
  # Each is [id, name, path]; the id names the icon.
  def settings_groups
    [
      [ "Profile", [ [ "account", "You", settings_account_path ] ] ],
      [ nil, [ [ "notifications", "Notifications", settings_notifications_path ], [ "watch", "Apple Watch", settings_watches_path ] ] ],
      [ nil, [
        ([ "models", "Models", subscriptions_path ] if Current.admin?),
        ([ "invitations", "Invitations", settings_invitations_path ] if Current.admin?),
        [ "workspaces", "Workspaces", workspaces_path ],
        # The workspace's the person used last, which each page names; a group's menu in the agents list opens another's.
        [ "connectors", "Connectors", workspace_connectors_path(Current.workspace) ],
        [ "helpers", "Helpers", workspace_helpers_path(Current.workspace) ],
        [ "usage", "Usage", workspace_usage_path(Current.workspace) ],
        ([ "wallet", "Wallet", settings_wallet_path ] if DurableAssistants::Link.configured?)
      ].compact ],
      [ "Agents", Current.workspace.agents.order(:name, :id).map { [ "agent", it.name, agent_path(it) ] } ]
    ]
  end

  # Notifications on this phone as its page says them (settings/notifications),
  # for the phone app's Notifications row: On for a token this session posted,
  # unless the app has said since that iOS refuses them, as it does each time
  # it comes to the front (Push::Device#reported). With no token, Off once the
  # app last said iOS refused: then the refusal is the person's, not the
  # session's (Push::Attempt).
  def notifications_status
    @notifications_status ||=
      if !Push.native? then "Not available"
      elsif (device = Current.user.push_devices.this_session(session)) then device.refused? ? "Off" : "On"
      elsif Current.user.push_attempts.order(id: :desc).pick(:outcome) == "refused" then "Off"
      else "Not set up"
      end
  end

  # What a place's row says on its right in the phone app's Settings tab, as
  # the app's own screen said it there. A page can't ask WatchConnectivity
  # whether a Watch is paired, only whether one holds a token Rails would
  # take, so the Watch's row says signed in, not connected.
  def settings_value(id)
    case id
    when "notifications" then notifications_status
    when "watch" then Current.user.watches.active.exists? ? "Signed in" : "Not signed in"
    end
  end

  # Where a place's row goes in the phone app. Notifications iOS refused
  # can only be allowed again in the iPhone's Settings, which Hotwire Native
  # opens for an address on another host (SystemNavigationRouteDecisionHandler).
  def settings_native_path(id, path)
    id == "notifications" && notifications_status == "Off" ? "app-settings:" : path
  end

  # The app's version and build, "0.1 (12)", from its user agent (AppDelegate: "Lanyard/0.1(12)").
  def native_app_version = request.user_agent.to_s[%r{\bLanyard/([^\s;]+)}, 1]&.sub("(", " (")

  # An agent's sections, in the order its settings list them. Computer and
  # Channels only where the install offers one; Helpers where the agent has
  # them, or had.
  def agent_sections(agent)
    [
      [ "General", agent_path(agent) ],
      [ "Instructions", agent_instructions_path(agent) ],
      [ "Tools", agent_tools_path(agent) ],
      [ "Skills", agent_skills_path(agent) ],
      [ "Commands", agent_prompts_path(agent) ],
      [ "Routines", agent_routines_path(agent) ],
      [ "Permissions", agent_permissions_path(agent) ],
      ([ "Helpers", agent_helpers_path(agent) ] if agent.capabilities.include?("subagents") || agent.helpers.exists?),
      ([ "Computer", agent_computer_path(agent) ] if Computer.providers(agent).any? || agent.computer),
      ([ "Channels", agent_channels_path(agent) ] if channels?(agent)),
      ([ "Concourse tasks", agent_peer_tasks_path(agent) ] if agent.concourse_agents.any?)
    ].compact
  end

  def channels?(agent) = agent.workspace.agents_mail? || DurableAssistants::Voipms.configured?(agent.voipms_account) || DurableAssistants::Caldav.configured? ||
    DurableAssistants::Passbolt.configured?(agent) || DurableAssistants::Concourse.configured? || agent.campfire.configured? || gmail_inbox_settings?(agent)

  def gmail_inbox_settings?(agent) = Agent::GmailInbox.owner_at_sign_in?(agent, Current.user, session[:email])

  # The open place, for aria-current: General is its own page alone; a
  # section is open on its pages under it too (a skill's form). An agent's
  # own connectors are part of its Tools.
  def settings_current?(path, exact: false)
    return path.end_with?("/tools") if controller_path == "conversations/connectors"
    # Any workspace's, or one of them: the sidebar's row is whichever the person used last.
    return path.end_with?("/#{controller_path}") if controller_path.in?(%w[ connectors helpers ])
    request.path == path || (!exact && request.path.start_with?("#{path}/"))
  end

  # /settings itself: on a phone, the list and nothing else.
  def settings_index? = controller_path == "settings"

  # The header's way back, on a phone: one level up, as iOS goes. A wide
  # screen has no header; the sidebar's first row goes out (settings_out_path).
  def settings_back_links
    label, path = settings_up
    link_to(label, path, class: "app-header__back settings__up", data: { up: true })
  end

  # Out of the settings: to the open agent's thread, or the agents.
  def settings_out_path = @agent&.conversation ? conversation_path(@agent.conversation) : root_path

  # A connector's status (McpServer#status) as a word and a colour.
  CONNECTOR_STATUSES = { "ok" => [ "Connected", "connected" ], "needs_sign_in" => [ "Needs sign-in", "attention" ],
    "failing" => [ "Error", "error" ], "off" => [ "Off", "off" ], "listing" => [ "Listing tools…", "off" ],
    "no_computer" => [ "No computer", "attention" ] }.freeze

  def connector_status(connector, conversation = nil)
    word, kind = CONNECTOR_STATUSES.fetch(connector.status(conversation))
    render "ui/status", text: word, kind: kind
  end

  # A connector added from the gallery shows as its service, with its own
  # name beside when that is not the service's: "Gmail · gmail_work".
  def connector_title(connector)
    key, entry = connector.gallery
    return connector.name unless entry
    connector.name == key.to_s ? entry[:label] : "#{entry[:label]} · #{connector.name}"
  end

  def connector_logo(connector) = connector_tile(connector.gallery&.last&.dig(:label) || connector.name)

  # A name for another account of a gallery service, free among the person's: gmail_2, gmail_3.
  def free_connector_name(key, taken) = (2..).lazy.map { "#{key}_#{it}" }.find { !taken.include?(it) }

  private
    def settings_up
      case controller_path
      when "settings" then [ "Agents", root_path ]
      when "agents" then [ "Settings", settings_path ]
      when "agents/skills" then action_name == "index" ? [ @agent.name, agent_path(@agent) ] : [ "Skills", agent_skills_path(@agent) ]
      when "agents/skills/updates" then [ @skill.name, agent_skill_path(@agent, @skill) ]
      when "agents/skills/approvals", "agents/skills/rejections", "agents/github_skills" then [ "Skills", agent_skills_path(@agent) ]
      when "agents/prompts" then action_name == "index" ? [ @agent.name, agent_path(@agent) ] : [ "Commands", agent_prompts_path(@agent) ]
      when "conversations/connectors" then [ "Tools", agent_tools_path(@agent) ]
      when %r{\Aagents/} then [ @agent.name, agent_path(@agent) ]
      when "connectors" then action_name == "show" ? [ "Connectors", workspace_connectors_path(Current.workspace) ] : [ "Settings", settings_path ]
      else [ "Settings", settings_path ]
      end
    end
end
