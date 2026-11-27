require "open3"
require "json"
require "tmpdir"
require "uri"
require_relative "passbolt/native"

module DurableAssistants
  # Read as the agent's own user when it has one, otherwise as the workspace's,
  # otherwise as the install's, on its workspace's own server if it has one,
  # otherwise on the install's (connection_for). HTTPS reads stay in this
  # process. The legacy internal HTTP accessory and saves still use the
  # existing commands. A failed HTTPS read never triggers a second request
  # through the CLI.
  module Passbolt
    # Something went wrong, in words a person or a model can read. Never
    # carries a password or what the command printed.
    class Error < StandardError; end

    # A workspace has a server of its own but no user to read it as. Nothing
    # is read anywhere: the install's server is never used in its place.
    class MissingVaultUser < Error; end

    # `answers` are its security questions' answers, each {question, answer}.
    # `account` is a site's separate account box (an account or customer
    # number), saved as a line "Account: ..." in the entry's description.
    SignIn = Data.define(:id, :name, :address, :username, :password, :answers, :account) do
      def initialize(answers: [], account: nil, **) = super
      # The site's host, which the browser's page must be on to be filled. A
      # bare "example.com", as people often save it, means its https site.
      def host
        site = address.to_s.strip
        site = "https://#{site}" unless site.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
        URI.parse(site).host&.downcase&.delete_suffix(".").presence
      rescue URI::InvalidURIError
        nil
      end

      # Printed in an error or a console, never with its password.
      def inspect = "#<SignIn #{name} #{address}>"
      alias_method :to_s, :inspect
    end

    TIMEOUT = 30 # seconds; the command's own --timeout, and passbolt-save's

    # Only these define --json (go-passbolt-cli's internal/cmd/list.go and
    # get.go); any other, such as share, refuses it as an unknown flag and
    # prints nothing worth reading when it succeeds.
    ANSWERS_IN_JSON = %w[ list get ]

    # Flags that would put a secret in the command's arguments: create's
    # --password (-p) and --secret-field, and the key, passphrase and TOTP
    # flags every command takes. A secret goes on standard input instead.
    SECRET_FLAG = /\A(-p|--(password|secret-field|userPassword|userPrivateKey|totpToken|mfaTotpToken)(\z|=))/

    def self.setting(key) = DurableAssistants.config(:passbolt, key)

    def self.configured?(agent)
      connection_for(agent).all?(&:present?)
    rescue MissingVaultUser
      false
    end

    # The accessory's address inside the host. The public one is for people,
    # behind the install's own sign-in (Cloudflare Access, say), which the app
    # could not pass.
    def self.url = setting(:url).presence || DurableAssistants.kamal_url("passbolt")

    # What is shared with the agents: names and addresses, no passwords.
    def self.sign_ins(agent)
      read(agent, "list").map do |entry|
        SignIn.new(id: entry["id"], name: entry["name"].to_s, address: entry["uri"].to_s, username: nil, password: nil)
      end.sort_by { it.name.downcase }
    end

    def self.find_by_name(agent, name)
      sign_ins(agent).find { it.name.casecmp?(name.to_s) } or raise Error, "Nothing called #{name} is shared with the agents."
    end

    # One entry with its password, its answers and its account, for the
    # browser and nothing else.
    def self.sign_in(agent, id)
      entry = read(agent, "read", id: id.to_s)
      SignIn.new(id: id.to_s, name: entry["name"].to_s, address: entry["uri"].to_s, username: entry["username"].to_s,
        password: entry["password"].to_s, answers: answers_in(entry), account: account_in(entry))
    end

    # How long the id a name was found at is kept. An id never changes while
    # its entry exists, and each read is still made as the holder's own user,
    # so the vault still decides what is shared. A day bounds how long the id
    # of a deleted or renamed entry lingers before it is dropped anyway.
    ENTRY_ID_KEPT = 1.day

    # sign_in(holder, find_by_name(holder, name).id), without listing the whole
    # vault each time: the entry's id, and nothing else, is kept per holder
    # and name. The vault answers an entry deleted or no longer shared as it
    # does any failure, so a kept id that fails, or now names another entry,
    # is dropped and the name looked up once more; an outage fails that
    # lookup too, and its error is the one raised.
    def self.sign_in_by_name(holder, name)
      key = [ "vault-entry-id", holder.class.name, holder&.id, name.to_s.downcase ]
      if (id = Rails.cache.read(key))
        entry = begin
          sign_in(holder, id)
        rescue Error
          nil
        end
        return entry if entry&.name&.casecmp?(name.to_s)
        Rails.cache.delete(key)
      end
      sign_in(holder, find_by_name(holder, name).id).tap { Rails.cache.write(key, it.id, expires_in: ENTRY_ID_KEPT) }
    end

    # The first "Account: ..." line of the entry's description. A
    # password-and-description entry encrypts its description with the
    # password, so go-passbolt-cli's get (0.5.3) prints it under "secret", and
    # at the top too when the metadata's own is blank.
    def self.account_in(entry)
      description = entry.dig("secret", "description").presence || entry["description"]
      description.to_s.each_line.filter_map { it[/\A\s*account\s*:(.*)/i, 1]&.strip.presence }.first
    end

    # Security questions as Passbolt keeps them, as custom fields: each one's
    # name (the question) in the entry's metadata and its value (the answer)
    # in its secret, the two halves matched by id. Either may be kept on the
    # other side, as Passbolt allows.
    def self.answers_in(entry)
      secrets = Array(entry.dig("secret", "custom_fields")).index_by { it["id"] }
      Array(entry.dig("metadata", "custom_fields")).filter_map do |field|
        secret = secrets[field["id"]] || {}
        question = (field["metadata_key"].presence || secret["secret_key"]).to_s
        answer = (secret["secret_value"].presence || field["metadata_value"]).to_s
        { "question" => question, "answer" => answer } if question.present? && answer.present?
      end
    end

    # A sign-in a person typed for the agents (Tool::AskForSignIn), owned by
    # the agents' user. go-passbolt-cli takes a new password only as an
    # argument, so passbolt-save (passbolt-save/main.go, built into the image)
    # creates it from standard input instead.
    def self.save(agent, name:, address:, username:, password:)
      raise Error, "A sign-in called #{name} is already saved; ask someone to change it in the password manager." if
        sign_ins(agent).any? { it.name.casecmp?(name.to_s) }
      execute(agent, "passbolt-save", input: { name: name.to_s, uri: address.to_s, username: username.to_s, password: password.to_s }.to_json)
    end

    # A sign-in someone outside typed into an empty entry (SignInLink).
    # passbolt-save's fill mode reads it on standard input, refuses an entry
    # that already has a password, puts the account in the entry's encrypted
    # description as the line account_in reads, and encrypts the secret again
    # for everyone the entry is shared with.
    def self.fill(agent, id, username:, password:, account: nil)
      execute(agent, "passbolt-save", "fill",
        input: { id: id.to_s, username: username.to_s, password: password.to_s, account: account.to_s.squish }.to_json)
    end

    # The server and user every call reaches the vault with: the first whole
    # pair of the agent's own, its workspace's (Workspace::VaultUser) and the
    # install's, on the workspace's own server if it names one, otherwise on
    # the install's. A workspace with its own server is never read on the
    # install's or as the install's user, so with no pair of its own (or its
    # agent's) it refuses. A workspace may ask for itself, for what no one
    # agent holds (a connector's app).
    def self.connection_for(agent)
      workspace = agent.is_a?(Workspace) ? agent : agent&.workspace
      user = [ agent, workspace ].compact.uniq.map { [ it.passbolt_private_key, it.passbolt_passphrase ] }.find { it.all?(&:present?) }
      if workspace&.passbolt_url.present?
        raise MissingVaultUser, "#{workspace}'s own password manager has no user set, so nothing is read from it or any other." unless user
        [ workspace.passbolt_url, *user ]
      else
        [ url, *(user || [ setting(:private_key), setting(:passphrase) ]) ]
      end
    end
    private_class_method :connection_for

    # connection_for, its workspace's own server resolved first, before every
    # call: a public name checked when it was saved may lead to this server or
    # its private network since (McpServer::Address). The install's own,
    # inside by design, is not a workspace's to name.
    def self.reachable_connection_for(agent)
      workspace = agent.is_a?(Workspace) ? agent : agent&.workspace
      connection_for(agent).tap do |origin, *|
        McpServer::Address.public_address(URI.parse(origin).host.to_s) if workspace&.passbolt_url.present?
      end
    rescue McpServer::Address::Refused => refused
      raise Error, "#{workspace}'s own password manager was not called: #{refused.message}.", cause: nil
    end
    private_class_method :reachable_connection_for

    def self.read(agent, operation, id: nil)
      origin, key, passphrase = reachable_connection_for(agent)
      raise Error, "Saved sign-ins are not set up here." if [ origin, key, passphrase ].any?(&:blank?)

      case URI.parse(origin).scheme
      when "https"
        Native.call(origin:, key: key.to_s.gsub("\\n", "\n"), passphrase:, operation:, id:, internal_hosts: internal_hosts(origin))
      when "http"
        if operation == "list"
          run(agent, "list", "resource", "--column", "id", "--column", "name", "--column", "uri")
        else
          run(agent, "get", "resource", "--id", id)
        end
      else
        raise Error, "The password manager could not be reached."
      end
    rescue URI::InvalidURIError
      raise Error, "The password manager could not be reached.", cause: nil
    end
    private_class_method :read

    def self.run(agent, *arguments)
      raise ArgumentError, "A secret goes to the password manager on standard input, never in its arguments." if
        arguments.any? { it.to_s.match?(SECRET_FLAG) }
      json = ANSWERS_IN_JSON.include?(arguments.first)
      execute(agent, "passbolt", *arguments, *("--json" if json), "--mfaMode", "none", "--timeout", "#{TIMEOUT}s", json:)
    end
    private_class_method :run

    def self.execute(agent, *command, input: "", json: true)
      origin, key, passphrase = reachable_connection_for(agent)
      raise Error, "Saved sign-ins are not set up here." if [ origin, key, passphrase ].any?(&:blank?)
      Dir.mktmpdir("passbolt") do |home|
        output, status = Open3.capture2(environment(home, origin, key, passphrase), *command, stdin_data: input,
          unsetenv_others: true, err: File::NULL)
        raise Error, "The password manager could not be reached." unless status.success?
        JSON.parse(output) if json
      end
    rescue Errno::ENOENT
      raise Error, "The password manager's command is not installed."
    rescue JSON::ParserError
      raise Error, "The password manager answered with something unreadable."
    end
    private_class_method :execute

    # Its configuration file would live under XDG_CONFIG_HOME; a fresh, empty
    # folder per call means only these settings apply. Kamal passes a
    # multi-line secret with its newlines escaped, and an armored key cannot
    # be read on one line, so a literal \n is a newline again.
    def self.environment(home, origin, private_key, passphrase)
      { "HOME" => home, "XDG_CONFIG_HOME" => home, "SERVERADDRESS" => origin, "INTERNAL_HOSTS" => internal_hosts(origin),
        "USERPRIVATEKEY" => private_key.to_s.gsub("\\n", "\n"), "USERPASSWORD" => passphrase }
    end
    private_class_method :environment

    # The hosts inside the install the vault's Go code may still connect to
    # (passbolt-save/vaultdial): those the operator lists for connectors
    # (McpServer::InternalHosts), and the install's own server, which the
    # operator set too, when it is the one called. Go refuses any other
    # connection that lands inside as it connects, so a name that passed
    # Rails' check cannot be rebound inside before the connection is made.
    def self.internal_hosts(origin)
      own = URI.parse(origin) if origin == url
      [ *McpServer::InternalHosts.listed.map { it.compact.join(":") }, ("#{own.hostname}:#{own.port}" if own&.hostname) ].compact.join(",")
    end
    private_class_method :internal_hosts
  end
end
