# Every ten minutes (config/recurring.yml), deliberately global: each person
# has the install's connectors (McpServer.install_for), so a new or changed one
# reaches everyone without a sign-in.
class InstallConnectorsJob < ApplicationJob
  limits_concurrency key: "install_connectors"

  def perform
    User.find_each { McpServer.install_for(it) } # tenancy-ok: the install's connectors are everyone's
  end
end
