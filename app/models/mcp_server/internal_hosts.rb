# Hosts inside the install, beside each office connector's own, that a
# workspace's own address for an office connector may name over plain http
# (Workspace::InstallConnector): a second wiki accessory one workspace keeps
# to itself, say. Only the operator lists them, in CONNECTORS__INTERNAL_HOSTS;
# no person or agent can. Each is an exact name, or name:port to allow that
# port alone, so a listed name opens no other: not a longer name, not an
# address, and nothing for a person's own connector.
module McpServer::InternalHosts
  def self.include?(uri)
    host = uri.host.to_s.downcase
    host.present? && listed.any? { |name, port| name == host && (port.nil? || port == uri.port) }
  end

  def self.listed
    DurableAssistants.config(:connectors, :internal_hosts).to_s.downcase.split(/[\s,]+/).filter_map do |entry|
      name, port = entry.split(":", 2)
      next if name.blank? || (port && !port.match?(/\A\d{1,5}\z/))
      [ name, port&.to_i ]
    end
  end
end
