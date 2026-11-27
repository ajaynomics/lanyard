# How a workspace's agents treat a call that asks for approval (#226): its
# owner's choice on its page, or, where they made none, the install's
# (APP__APPROVE_EVERYTHING, then APP__APPROVALS). Agent#allows? asks it; what
# asks even where everything is approved, and a person's "Always", are
# decided there, so no policy here reaches them.
class Workspace::ApprovalPolicy
  # What an owner may choose, as their page offers it, beside the install's
  # default. Nothing stricter than "others": an owner loosens their own
  # workspace or leaves it to the install, whose "ask" stays the strictest.
  CHOICES = {
    "others" => "Ask before what reaches other people",
    "everything" => "Approve everything"
  }.freeze

  # The install's own policies, which no workspace chooses.
  INSTALL_ONLY = {
    "allow" => "Allow everything",
    "ask" => "Ask before anything"
  }.freeze

  def self.of(workspace) = new(workspace.approval_policy || install_default)

  # The install's settings, which were the whole policy before workspaces chose.
  def self.install_default
    if DurableAssistants.config(:app, :approve_everything) then "everything"
    elsif DurableAssistants.config(:app, :approvals) == "allow" then "allow"
    else "ask"
    end
  end

  attr_reader :name

  def initialize(name) = @name = name

  # Whether a call of `tool` runs unasked under this policy alone. "allow" is
  # the install's APP__APPROVALS=allow, no workspace's choice: as "everything",
  # except what asks every time. "others" is "allow" except what reaches
  # another person or changes the agent itself (Tool.reaches_others,
  # Tool.changes_itself), or a send that stays inside (Tool#reaches_outsiders?).
  # "ask", the install's when neither setting is on,
  # leaves every call to a person's "Always".
  def allows?(tool)
    case name
    when "everything" then true
    when "allow" then !tool.every_time?
    when "others" then !tool.every_time? && !tool.reaches_outsiders? && !tool.changes_itself?
    else false
    end
  end

  def everything? = name == "everything"
  def allow? = name == "allow"
  def others? = name == "others"

  def to_s = CHOICES.merge(INSTALL_ONLY).fetch(name)
end
