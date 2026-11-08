# The settings' places and their words (layouts/settings): the sidebar, an
# agent's sections, the way back up on a phone, and a status as a word.
module SettingsHelper
  # An agent's sections, in the order its settings list them. Computer and
  # Channels only where the install offers one.
  def agent_sections(agent)
    [
      [ "General", agent_path(agent) ],
      [ "Instructions", agent_instructions_path(agent) ],
      [ "Tools", agent_tools_path(agent) ],
      [ "Skills", agent_skills_path(agent) ],
      [ "Commands", agent_prompts_path(agent) ],
      [ "Routines", agent_routines_path(agent) ],
      [ "Permissions", agent_permissions_path(agent) ],
      ([ "Computer", agent_computer_path(agent) ] if Computer.providers.any? || agent.computer),
      ([ "Channels", agent_channels_path(agent) ] if channels?)
    ].compact
  end

  def channels? = DurableAssistants::Email.configured? || DurableAssistants::Voipms.configured? || DurableAssistants::Concourse.configured? || CampfireBot.configured?

  # The open place, for aria-current: General is its own page alone; a
  # section is open on its pages under it too (a skill's form). An agent's
  # own connectors are part of its Tools.
  def settings_current?(path, exact: false)
    return path.end_with?("/tools") if controller_path == "conversations/connectors"
    request.path == path || (!exact && request.path.start_with?("#{path}/"))
  end

  # /settings itself: on a phone, the list and nothing else.
  def settings_index? = controller_path == "settings"

  # The header's way back, on a phone: one level up, as iOS goes. A wide
  # screen has no header; the sidebar's first row goes out (settings_out_path).
  def settings_back_links
    label, path = settings_up
    link_to("‹ #{label}", path, class: "app-header__back settings__up", data: { settings_up: true })
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
      when "agents/prompts" then action_name == "index" ? [ @agent.name, agent_path(@agent) ] : [ "Commands", agent_prompts_path(@agent) ]
      when "conversations/connectors" then [ "Tools", agent_tools_path(@agent) ]
      when %r{\Aagents/} then [ @agent.name, agent_path(@agent) ]
      when "connectors" then action_name == "show" ? [ "Connectors", connectors_path ] : [ "Settings", settings_path ]
      else [ "Settings", settings_path ]
      end
    end
end
