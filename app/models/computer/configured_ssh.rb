class Computer::ConfiguredSsh
  KIND = "configured_ssh"
  RECORD_ID = /\A[1-9][0-9]*\z/
  BASE = %r{\A(?:/[a-zA-Z0-9_-][a-zA-Z0-9._-]*)+\z}
  KEYRING = /\Aconfigured-[a-z0-9][a-z0-9-]{0,47}\z/

  def self.listed?(list, agent_id)
    ids = list.to_s.split(",", -1).map(&:strip)
    ids.all? { RECORD_ID.match?(it) } && ids.include?(agent_id.to_s)
  end

  def self.descriptor(agent)
    return unless agent&.persisted? && agent.workspace&.personal?
    return unless DurableAssistants.config(:pi_durable, :computers, default: []).include?(KIND)

    settings = DurableAssistants.config(:pi_durable, :configured_ssh, default: {})
    return unless settings[:workspace_id].to_s == agent.workspace_id.to_s

    return unless listed?(settings[:agent_ids], agent.id)

    host, user, base, keyring = settings.values_at(:host, :user, :base, :keyring).map(&:to_s)
    slug = agent.email_name.to_s
    return unless Computer::SSH_HOST.match?(host) && Computer::SSH_USER.match?(user) && BASE.match?(base) &&
      KEYRING.match?(keyring) && Agent::EMAIL_NAME.match?(slug)

    folder = "#{base}/#{slug}"
    return if folder.bytesize > 1024

    { provider: "ssh", host: host, user: user, folder: folder, keyring: keyring }
  end
end
