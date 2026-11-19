# A person's per-agent choice, stronger than old "Always" answers and the
# install's approval policy, but for an Always with every recipient of the
# call where the tool takes one (Tool.always_with_recipients). Prepend so it
# also covers a tool's own shortcut, such as email to an admitted person. Off
# leaves that tool's rules alone.
module Tool::AsksEverySend
  SETTINGS = {
    "send_email" => [ :asks_every_email, "Ask before every email" ],
    "send_text" => [ :asks_every_text, "Ask before every text message" ],
    "imessage_send" => [ :asks_every_imessage, "Ask before every iMessage" ],
    "concourse_send" => [ :asks_every_concourse_send, "Also ask before Concourse messages" ]
  }.freeze

  def asks_every_send? = agent.public_send(SETTINGS.fetch(self.class.tool_name).first)
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
    note = "#{agent} is set to #{SETTINGS.fetch(self.class.tool_name).last.downcase_first}, so this asks every time"
    return "#{note}." unless always_with_recipients?
    "#{note}, except where you allowed each recipient Always: #{always_label} covers a message only when every recipient, " \
      "in To, Cc and Bcc, is one of them."
  end
end
