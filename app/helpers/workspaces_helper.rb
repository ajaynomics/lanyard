module WorkspacesHelper
  # An agent's state on Workspaces › Overview (Workspace::Health#states), as a word and a colour.
  AGENT_STATES = { "running" => [ "Working", "working" ], "idle" => [ "Idle", "connected" ], "paused" => [ "Paused", "off" ],
    "error" => [ "In error", "error" ], "unknown" => [ "Unknown", "off" ] }.freeze

  def agent_state(state)
    text, kind = AGENT_STATES.fetch(state)
    render "ui/status", text:, kind:
  end

  # A workspace's colour, by name: hues tokens.css draws at its fixed
  # lightness, so white text on each still passes 4.5:1.
  ACCENT_HUES = { 25 => "Red", 50 => "Orange", 100 => "Olive", 145 => "Green", 185 => "Teal", 215 => "Cyan",
    255 => "Blue", 280 => "Indigo", 305 => "Purple", 340 => "Pink" }.freeze

  # First what a blank leaves it to, the install's, then each named hue, with
  # whatever hue is saved even if it has no name (an operator's, say).
  def accent_hue_options(saved)
    [ [ "The install's (#{accent_hue_name(DurableAssistants.accent_hue)})", "" ] ] +
      (ACCENT_HUES.keys | [ saved ].compact).sort.map { [ accent_hue_name(it), it ] }
  end

  def accent_hue_name(hue) = ACCENT_HUES.fetch(hue) { "Hue #{hue}" }
end
