class Tool::Forge::Binding
  COMPONENT = /[a-zA-Z0-9][a-zA-Z0-9_-]*/
  REPO = %r{\A#{COMPONENT}/#{COMPONENT}\z}
  NAMESPACE = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  SOCKET = %r{\A(?:/#{COMPONENT})*/#{COMPONENT}\.sock\z}

  attr_reader :socket_path

  def self.for(agent)
    settings = DurableAssistants.config(:forge, default: {})
    return unless agent.persisted? && settings[:agent_id].to_s == agent.id.to_s && settings[:workspace_id].to_s == agent.workspace_id.to_s
    return unless fits?(settings[:branch_namespace], NAMESPACE, limit: 64) && fits?(settings[:socket_path], SOCKET, limit: 100)

    repos = settings[:repos].to_s.split(",", -1).map(&:strip)
    return unless repos.size == 6 && repos.uniq.size == 6 && repos.all? { |repo| fits?(repo, REPO, limit: 160) }
    return unless repos.map { |repo| repo.split("/", 2).first }.uniq.one?

    new(repos, settings[:branch_namespace], settings[:socket_path])
  end

  def self.fits?(value, pattern, limit:) = value.is_a?(String) && value.bytesize <= limit && pattern.match?(value)

  def initialize(repos, branch_namespace, socket_path)
    @repos, @branch_namespace, @socket_path = repos, branch_namespace, socket_path
  end

  def allows?(operation)
    return false unless Tool::Forge::Wire.allowed?(operation) && @repos.include?(operation["repo"])
    return true unless operation["verb"] == "push"

    operation["branch"].start_with?("#{@branch_namespace}/")
  end
end
