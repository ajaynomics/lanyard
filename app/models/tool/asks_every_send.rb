# A stricter send rule wins over an old "Always" or a permissive approval
# policy. Prepend so it also covers a tool's own shortcut, such as email to
# an admitted person.
module Tool::AsksEverySend
  SETTINGS = {
    "send_email" => [ :asks_every_email, "Ask before every email" ],
    "send_text" => [ :asks_every_text, "Ask before every text message" ],
    "imessage_send" => [ :asks_every_imessage, "Ask before every iMessage" ],
    "concourse_send" => [ :asks_every_concourse_send, "Ask before every Concourse send" ]
  }.freeze

  REPLY_SETTING = { "concourse_reply" => "concourse_send" }.freeze
  TOOL_SETTINGS = SETTINGS.merge(REPLY_SETTING.transform_values { SETTINGS.fetch(it) }).freeze

  def asks_every_send? = agent.asks_every_send?(self.class.tool_name)
  # Off restores new calls' rules, not a decision already waiting on the person.
  def asks = (asks_every_send? || invocation.awaiting_person?) ? :approval : super
  def always? = !asks_every_send? && super
  def every_time? = asks_every_send? || super
  def even_approving_everything? = asks_every_send? || super

  def approval_title(arguments)
    return unless asks_every_send?
    self.class.try(:approval_title, arguments) || "Allow #{self.class.tool_name.humanize(capitalize: false)} as #{agent}?"
  end

  def approval_note(_arguments)
    return unless asks_every_send?
    "#{agent} is set to #{TOOL_SETTINGS.fetch(self.class.tool_name).last.downcase_first}, so this asks every time."
  end
end
