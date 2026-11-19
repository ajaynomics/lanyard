# Every ten minutes (config/recurring.yml), deliberately global: each office
# connector a workspace turned on follows the install (McpServer.install_for),
# so a changed address or a removed key reaches everyone without a sign-in,
# and one a workspace may no longer use the install's key for goes off.
class InstallConnectorsJob < ApplicationJob
  limits_concurrency key: "install_connectors"

  def perform
    Workspace.find_each { McpServer.install_for(it) } # tenancy-ok: the install's connectors are kept in line in every workspace
  end
end
