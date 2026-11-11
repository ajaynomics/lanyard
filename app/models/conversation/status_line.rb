# Where a conversation stands, for the line above its composer and the
# Details under it (conversations/_status_line): which model and effort,
# who pays, how full the model's context is, what the thread has read and
# written, and how its Concourse mail is doing. It answers in facts; the
# views put them in words. Quiet unless something needs the person: the
# context nearly at its summary point, or Concourse not delivering.
class Conversation::StatusLine
  # Within this share of the summary point, the line says it is getting full.
  NEARLY_FULL = 0.85

  attr_reader :conversation

  delegate :agent, to: :conversation

  def initialize(conversation)
    @conversation = conversation
  end

  # "Opus 5.5" for the line, "Claude Opus 5.5" for Details.
  def model_name = ModelCatalog.plain_name(agent.model)
  def short_model_name = model_name.delete_prefix("Claude ")
  def effort = Agent::THINKING_LEVEL_NAMES.fetch(agent.thinking_level, agent.thinking_level)

  # A subscription's turns are in its plan; an API key's are billed at the price.
  def subscription? = ModelCatalog::SOURCES[agent.model.to_s.split("/").first] == "Subscription"
  def cost = totals["cost"]

  def context_tokens = (conversation.context_tokens unless summarised?)
  def summarised? = conversation.summarised_since_last_reply?
  def context_window = ModelCatalog.context_window(agent.model)
  def compact_at = ModelCatalog.compact_at(agent.model)

  # How full the context is, of the model's whole window where it is known,
  # else of the point where earlier messages are summarised.
  def room_used
    return unless context_tokens && (size = context_window || compact_at)
    [ context_tokens.fdiv(size), 1.0 ].min
  end

  def nearly_full? = context_tokens.present? && compact_at.present? && context_tokens >= compact_at * NEARLY_FULL

  def last_summarised_at = conversation.messages.where(role: "summary").maximum(:created_at)

  # What every call has read: from the cache, newly written to it, and not cached.
  def read = totals.values_at("cacheRead", "cacheWrite", "input").sum(&:to_i)
  def read_from_cache = totals["cacheRead"].to_i
  def read_newly_cached = totals["cacheWrite"].to_i
  def read_new = totals["input"].to_i
  def written = totals["output"].to_i
  def cache_rate = (read_from_cache.fdiv(read) if read.positive?)

  def concourse_agents = @concourse_agents ||= agent.concourse_agents.to_a
  def concourse? = concourse_agents.any?
  def networks? = concourse_agents.many?

  # The network the line speaks for: one in trouble, else one waiting, else the first.
  def concourse_agent = concourse_agents.min_by { [ trouble?(it) ? 0 : it.awaiting_approval? ? 1 : 2, it.id ] }

  # Mail can't arrive: Concourse refused the agent or can't be reached.
  def concourse_trouble? = concourse? && trouble?(concourse_agent)

  def mail = conversation.messages.concourse_mail
  def mail_today = mail.where(created_at: Time.current.in_time_zone(agent.time_zone).all_day).count
  def last_mail_at = mail.maximum(:created_at)

  # Open Concourse tasks across the agent's thread and its branches.
  def open_tasks = agent.current_peer_tasks.open

  def attention? = nearly_full? || concourse_trouble?

  private
    def totals = conversation.usage.to_h

    def trouble?(concourse_agent) = !concourse_agent.connected? && !concourse_agent.awaiting_approval?
end
