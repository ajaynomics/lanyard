# Where the agent's own calendars and task lists live when they are not on
# the install's CalDAV server (docs/calendar.md, "Its own calendar server",
# #77): its account's calendar home on a server of its own, and the vault
# entry holding that account's username and password. Only the owner of the
# agent's workspace sets it. Set and usable, it replaces the install's
# account for this agent (Agent#caldav); the agent reaches the home through
# DurableAssistants::Caldav::Home and never holds the password.
#
# Or a server whose calendars and task lists it only reads (read_only), such
# as a colleague's whose work it took over: they sit beside its own, and
# nothing is saved or deleted there (DurableAssistants::Caldav::ReadOnly).
# It writes to one at most, the one not read only (Agent#calendar_server).
class Agent::CalendarServer < ApplicationRecord
  belongs_to :agent

  normalizes :url, with: -> { it.strip.presence }
  normalizes :vault_entry, with: -> { it.squish.presence }

  scope :read_only, -> { where(read_only: true) }

  validates :agent_id, uniqueness: { conditions: -> { where(read_only: false) } }, unless: :read_only?
  validates :url, uniqueness: { scope: :agent_id, message: "is already one of its calendar servers" }
  # Its lists are named for its host (Caldav::ReadOnly), so two read only are on two hosts.
  validate :one_read_only_per_host, if: -> { read_only? && url }
  attr_readonly :read_only
  validates :url, presence: true, length: { maximum: 500 }
  validates :vault_entry, presence: true, length: { maximum: 200 }
  validate :url_is_a_calendar_home, if: :url

  # Used only where the agent can read the vault; otherwise the install's account, as before.
  def usable? = DurableAssistants::Passbolt.configured?(agent)

  def caldav
    home = DurableAssistants::Caldav::Home.new(agent, home: url, entry: vault_entry)
    read_only? ? DurableAssistants::Caldav::ReadOnly.new(home, host) : home
  end

  def host = URI(url).host

  private
    def one_read_only_per_host
      others = agent.calendar_servers.read_only.where.not(id: id).map(&:host)
      errors.add(:url, "is on a server it already reads; one read-only server per host") if others.include?(host)
    rescue URI::InvalidURIError
      nil
    end

    # One https address, with a path of its own: the server's top is every
    # account's. URI would resolve . and .. away, so what was typed is
    # checked, %2e too, as a server may decode it.
    def url_is_a_calendar_home
      uri = URI(url) rescue nil
      segments = url.split(/[?#]/, 2).first.to_s.split("/").map { it.gsub(/%2e/i, ".") }
      problem =
        if uri&.scheme != "https" || uri.host.blank? then "must be an https address"
        elsif uri.userinfo || uri.query || uri.fragment then "must be a plain address, with no sign-in, query or #"
        elsif segments.intersect?(%w[ . .. ]) then "must not have . or .. in its path"
        elsif uri.path.delete_prefix("/").empty? then "must be the address of its calendars, not the server's top"
        end
      errors.add(:url, problem) if problem
    end
end
