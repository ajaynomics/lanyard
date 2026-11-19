# A workspace's own address and key for one of the install's connectors
# (config/install_connectors.yml): its agents reach the wiki, say, as the
# workspace's own member, bounded by what that member may read
# (docs/design/workspaces.md, sections 2.2 and 2.4). Its connector uses them
# instead of the install's (McpServer.install_for), the office's tool
# patterns and `loaded` still holding; without an address it keeps the
# install's. The key is kept encrypted and shown to nobody.
class Workspace::InstallConnector < ApplicationRecord
  belongs_to :workspace

  encrypts :api_key
  normalizes :url, :api_key, with: -> { it.strip.presence }

  validates :name, inclusion: { in: ->(_) { McpServer.install_entries.keys }, message: "is not one of the install's connectors" },
    uniqueness: { scope: :workspace }
  validates :api_key, presence: true
  validate :public_or_the_installs, if: :url

  # The workspace's connector follows at once; with a new key it lists its tools again.
  after_commit :reach_the_connector

  def to_param = name

  # The install's entry as this workspace has it.
  def over(entry) = entry.merge(url: url || entry[:url], api_key: api_key)

  private
    # The install's own host, or one the operator lists, may be inside it,
    # over plain http, as the install's own entry is. Anywhere else is reached
    # as a person's connector is: https, and never this server or its private network.
    def public_or_the_installs
      uri = URI.parse(url)
      return if uri.is_a?(URI::HTTP) && McpServer.inside_the_install?(name, uri)
      return errors.add(:url, "must start with https://") unless uri.is_a?(URI::HTTPS) && uri.host.present?
      errors.add(:url, "can't be this server or its private network") if McpServer.internal?(uri.host)
    rescue URI::InvalidURIError
      errors.add(:url, "is not a web address")
    end

    def reach_the_connector
      workspace.install_connectors.reset
      McpServer.install_for(workspace)
      connector = workspace.mcp_servers.global.find_by(install: name)
      McpServerRefreshJob.perform_later(connector) if connector && !connector.refreshing?
    end
end
