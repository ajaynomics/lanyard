# How the app presents itself to a workspace's people: its name and colour on
# their pages, and the host the links in their mail go to. The install's
# (APP__NAME, APP__ACCENT_HUE, APP__URL), or a workspace's own where set
# (Workspace#brand, #229): the name and colour by its owner, the host by the
# install's operator. The installed app and its icon stay the install's: a
# phone keeps one per install.
class Brand
  def self.install = new

  def initialize(workspace = nil)
    @workspace = workspace
  end

  def name = @workspace&.app_name || DurableAssistants.config(:app, :name)

  def accent_hue = @workspace&.accent_hue || DurableAssistants.accent_hue

  # For url helpers: the workspace's own host, or nothing, leaving
  # APP__URL's. Asked again at each link, so a host the install has since
  # stopped answering on (config.hosts) is never linked to.
  def url_options
    host = @workspace&.link_host
    return {} unless host && DurableAssistants.public_hosts.include?(host)
    { host: host, protocol: URI(DurableAssistants.config(:app, :url).to_s).scheme || "https" }
  end
end
