require "open3"
require "json"
require "tmpdir"

module DurableAssistants
  # The install's Passbolt, reached through its own command-line client
  # (go-passbolt-cli, the `passbolt` command in the image) as the one user the
  # agents share. This file is the only code that speaks to it. The user's key
  # and passphrase go to the command in its environment, never its arguments,
  # and nothing it prints is logged.
  module Passbolt
    # Something went wrong, in words a person or a model can read. Never
    # carries a password or what the command printed.
    class Error < StandardError; end

    SignIn = Data.define(:id, :name, :address, :username, :password) do
      # The site's host, which the browser's page must be on to be filled.
      def host
        URI.parse(address.to_s).host&.downcase&.delete_suffix(".")
      rescue URI::InvalidURIError
        nil
      end

      # Printed in an error or a console, never with its password.
      def inspect = "#<SignIn #{name} #{address}>"
      alias_method :to_s, :inspect
    end

    TIMEOUT = 30 # seconds; the command's own --timeout

    def self.setting(key) = DurableAssistants.config(:passbolt, key)

    def self.configured? = %i[ url private_key passphrase ].all? { setting(it).present? }

    # What is shared with the agents: names and addresses, no passwords.
    def self.sign_ins
      run("list", "resource", "--column", "id", "--column", "name", "--column", "uri").map do |entry|
        SignIn.new(id: entry["id"], name: entry["name"].to_s, address: entry["uri"].to_s, username: nil, password: nil)
      end.sort_by { it.name.downcase }
    end

    def self.find_by_name(name)
      sign_ins.find { it.name.casecmp?(name.to_s) } or raise Error, "Nothing called #{name} is shared with the agents."
    end

    # One entry with its password, for the browser and nothing else.
    def self.sign_in(id)
      entry = run("get", "resource", "--id", id.to_s)
      SignIn.new(id: id.to_s, name: entry["name"].to_s, address: entry["uri"].to_s, username: entry["username"].to_s, password: entry["password"].to_s)
    end

    def self.run(*arguments)
      raise Error, "Saved sign-ins are not set up here." unless configured?
      Dir.mktmpdir("passbolt") do |home|
        output, status = Open3.capture2(environment(home), "passbolt", *arguments, "--json", "--mfaMode", "none",
          "--timeout", "#{TIMEOUT}s", unsetenv_others: true, err: File::NULL)
        raise Error, "The password manager could not be reached." unless status.success?
        JSON.parse(output)
      end
    rescue Errno::ENOENT
      raise Error, "The password manager's command is not installed."
    rescue JSON::ParserError
      raise Error, "The password manager answered with something unreadable."
    end
    private_class_method :run

    # Its configuration file would live under XDG_CONFIG_HOME; a fresh, empty
    # folder per call means only these settings apply.
    def self.environment(home)
      { "HOME" => home, "XDG_CONFIG_HOME" => home,
        "SERVERADDRESS" => setting(:url), "USERPRIVATEKEY" => setting(:private_key), "USERPASSWORD" => setting(:passphrase) }
    end
    private_class_method :environment
  end
end
