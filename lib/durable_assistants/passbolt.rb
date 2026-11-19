require "open3"
require "json"
require "tmpdir"

module DurableAssistants
  # The install's Passbolt, reached through its own command-line client
  # (go-passbolt-cli, the `passbolt` command in the image) as the agent's own
  # Passbolt user when it has one (Agent#passbolt_private_key), so what it
  # saves and reads is its own and Passbolt's groups share between agents;
  # otherwise as its workspace's user when that has one (Workspace::VaultUser),
  # and otherwise as the one user the install's agents share. This file is the only code
  # that speaks to it. The user's key and passphrase go to the command in its
  # environment and a new password on its standard input, never in its
  # arguments, which every account on the host can read (/proc/<pid>/cmdline).
  # Nothing it prints is logged.
  module Passbolt
    # Something went wrong, in words a person or a model can read. Never
    # carries a password or what the command printed.
    class Error < StandardError; end

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

    def self.configured?(agent) = url.present? && key_for(agent).all?(&:present?)

    # The accessory's address inside the host. The public one is for people,
    # behind the install's own sign-in (Cloudflare Access, say), which the app
    # could not pass.
    def self.url = setting(:url).presence || DurableAssistants.kamal_url("passbolt")

    # What is shared with the agents: names and addresses, no passwords.
    def self.sign_ins(agent)
      run(agent, "list", "resource", "--column", "id", "--column", "name", "--column", "uri").map do |entry|
        SignIn.new(id: entry["id"], name: entry["name"].to_s, address: entry["uri"].to_s, username: nil, password: nil)
      end.sort_by { it.name.downcase }
    end

    def self.find_by_name(agent, name)
      sign_ins(agent).find { it.name.casecmp?(name.to_s) } or raise Error, "Nothing called #{name} is shared with the agents."
    end

    # One entry with its password, its answers and its account, for the
    # browser and nothing else.
    def self.sign_in(agent, id)
      entry = run(agent, "get", "resource", "--id", id.to_s)
      SignIn.new(id: id.to_s, name: entry["name"].to_s, address: entry["uri"].to_s, username: entry["username"].to_s,
        password: entry["password"].to_s, answers: answers_in(entry), account: account_in(entry))
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

    # The first whole pair of the agent's own, its workspace's
    # (Workspace::VaultUser) and the install's. Every call reaches the vault
    # through this, so a workspace with its own user never reads as the install's.
    # A workspace may ask for itself, for what no one agent holds (a connector's app).
    def self.key_for(agent)
      (agent.is_a?(Workspace) ? [ agent ] : [ agent, agent&.workspace ]).compact.map { [ it.passbolt_private_key, it.passbolt_passphrase ] }
        .find { it.all?(&:present?) } || [ setting(:private_key), setting(:passphrase) ]
    end
    private_class_method :key_for

    def self.run(agent, *arguments)
      raise ArgumentError, "A secret goes to the password manager on standard input, never in its arguments." if
        arguments.any? { it.to_s.match?(SECRET_FLAG) }
      json = ANSWERS_IN_JSON.include?(arguments.first)
      execute(agent, "passbolt", *arguments, *("--json" if json), "--mfaMode", "none", "--timeout", "#{TIMEOUT}s", json:)
    end
    private_class_method :run

    def self.execute(agent, *command, input: "", json: true)
      raise Error, "Saved sign-ins are not set up here." unless configured?(agent)
      Dir.mktmpdir("passbolt") do |home|
        output, status = Open3.capture2(environment(home, *key_for(agent)), *command, stdin_data: input,
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
    def self.environment(home, private_key, passphrase)
      { "HOME" => home, "XDG_CONFIG_HOME" => home, "SERVERADDRESS" => url,
        "USERPRIVATEKEY" => private_key.to_s.gsub("\\n", "\n"), "USERPASSWORD" => passphrase }
    end
    private_class_method :environment
  end
end
