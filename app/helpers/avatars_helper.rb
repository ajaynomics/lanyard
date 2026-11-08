module AvatarsHelper
  # An agent's face, as Campfire draws a person's: its initials on one of a
  # fixed set of colours (tokens.css, --avatar-0 to 7), chosen by its id so it
  # never changes. The initials are CSS content, not text, so the agent's name
  # beside it reads once, to a screen reader and in a link. Decorative: the
  # name is always beside it. A photo, when an agent has one, would take the
  # circle's place here.
  AVATAR_COLOURS = 8

  def agent_avatar(agent, size: nil)
    tag.span class: "ui-avatar", aria: { hidden: true }, data: { initials: initials(agent.name), colour: agent.id.to_i % AVATAR_COLOURS, size: size }
  end

  # The person's own, the same way, in the settings' You.
  def person_avatar(user, size: nil)
    tag.span class: "ui-avatar", aria: { hidden: true }, data: { initials: initials(user.to_s), colour: user.id.to_i % AVATAR_COLOURS, size: size }
  end

  # A connector's logo: its initial on a tile, coloured by its name, until
  # services have logos of their own here.
  def connector_tile(name)
    tag.span class: "ui-tile", aria: { hidden: true }, data: { initials: name.to_s.first.upcase, colour: name.to_s.sum % AVATAR_COLOURS }
  end

  # A place in the settings, as a Mac draws one: a small icon on a tile (its mask is in settings.css).
  def settings_tile(name)
    tag.span class: "ui-tile", aria: { hidden: true }, data: { icon: name }
  end

  private
    def initials(name) = name.to_s.scan(/[[:alnum:]]+/).first(2).map { it[0] }.join.upcase.presence || "?"
end
