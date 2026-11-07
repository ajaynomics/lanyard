module AvatarsHelper
  # An agent's face, as Campfire draws a person's: its initials on one of a
  # fixed set of colours (tokens.css, --avatar-0 to 7), chosen by its id so it
  # never changes. The initials are CSS content, not text, so the agent's name
  # beside it reads once, to a screen reader and in a link. Decorative: the
  # name is always beside it. A photo, when an agent has one, would take the
  # circle's place here.
  AVATAR_COLOURS = 8

  def agent_avatar(agent, size: nil)
    initials = agent.name.to_s.scan(/[[:alnum:]]+/).first(2).map { it[0] }.join.upcase.presence || "?"
    tag.span class: "ui-avatar", aria: { hidden: true }, data: { initials: initials, colour: agent.id.to_i % AVATAR_COLOURS, size: size }
  end
end
