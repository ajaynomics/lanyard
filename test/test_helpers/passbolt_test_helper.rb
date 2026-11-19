# Stand-in `passbolt` and `passbolt-save` commands on PATH, so
# lib/durable_assistants/passbolt.rb runs for real: they record each call's
# arguments, standard input and environment, and print one shared sign-in, as
# go-passbolt-cli's --json does. Like the real one (0.5.3), only list, get and
# create define --json; any other subcommand refuses it as cobra does an
# unknown flag.
module PassboltTestHelper
  PASSWORD = "correct-horse-battery-staple-7731"
  QUESTION = "What was the name of your first school?"
  ANSWER = "lighthouse-meadow-4410"
  PRIVATE_KEY = "-----BEGIN PGP PRIVATE KEY BLOCK-----\nsynthetic\n-----END PGP PRIVATE KEY BLOCK-----"
  PASSPHRASE = "synthetic-passphrase-for-the-agents"

  # password: "" stands for an entry someone made with nothing saved in it
  # yet, for a person outside to fill (SignInLink).
  def install_fake_passbolt(fail: false, name: "Bank", uri: "https://bank.example/login", description: nil, password: PASSWORD, username: "maya")
    @passbolt_dir = Dir.mktmpdir("fake-passbolt")
    @passbolt_calls = File.join(@passbolt_dir, "calls")
    listed = [ { id: "7f0c", name:, uri: } ].to_json
    # A password-and-description entry keeps its description in the secret;
    # go-passbolt-cli 0.5.3's get prints it there, and at the top as well
    # when the metadata's own is blank, as it then is.
    secret = { password:, custom_fields: [ { id: "c1", type: "text", secret_value: ANSWER } ] }
    secret[:description] = description if description
    entry = { name:, uri:, username:, password:, description: description.to_s,
      metadata: { custom_fields: [ { id: "c1", type: "text", metadata_key: QUESTION } ] }, secret: }.to_json
    File.write(File.join(@passbolt_dir, "passbolt-save"), <<~SH)
      #!/bin/sh
      { echo "SAVE ARGS $*"; echo "SAVE INPUT $(cat)"; env | grep -E '^(SERVERADDRESS|USERPRIVATEKEY|USERPASSWORD)=' | cut -d= -f1
        echo "USER $(printf '%s|%s' "$USERPRIVATEKEY" "$USERPASSWORD" | sha256sum | cut -c1-16)"
        case "$USERPASSWORD" in "#{PASSPHRASE}") echo "AS the shared user" ;; *) echo "AS another user" ;; esac; } >> #{@passbolt_calls}
      #{fail ? "exit 1" : "echo '{\"id\":\"9a1\"}'"}
    SH
    File.write(File.join(@passbolt_dir, "passbolt"), <<~SH)
      #!/bin/sh
      { echo "ARGS $*"; env | grep -E '^(SERVERADDRESS|USERPRIVATEKEY|USERPASSWORD|XDG_CONFIG_HOME)=' | cut -d= -f1
        echo "KEY LINES $(printf '%s\n' "$USERPRIVATEKEY" | wc -l | tr -d ' ')"
        echo "USER $(printf '%s|%s' "$USERPRIVATEKEY" "$USERPASSWORD" | sha256sum | cut -c1-16)"
        case "$USERPASSWORD" in "#{PASSPHRASE}") echo "AS the shared user" ;; *) echo "AS another user" ;; esac; } >> #{@passbolt_calls}
      #{fail ? "echo 'boom #{PASSWORD}' >&2; exit 1" : ""}
      case "$1 $*" in
        list*|get*|create*) ;;
        *" --json"*) echo 'Error: unknown flag: --json' >&2; exit 1 ;;
      esac
      case "$1 $2" in
        "list resource") printf '%s\n' '#{listed}' ;;
        "get resource") printf '%s\n' '#{entry}' ;;
        "create resource") echo '{"id":"9a1"}' ;;
      esac
    SH
    File.chmod(0o755, File.join(@passbolt_dir, "passbolt"), File.join(@passbolt_dir, "passbolt-save"))
    @previous_path = ENV["PATH"]
    ENV["PATH"] = "#{@passbolt_dir}:#{ENV['PATH']}"
    settings = Rails.application.config.x.passbolt
    @previous_passbolt = settings.dup
    settings.merge!(url: "https://passwords.example", private_key: PRIVATE_KEY, passphrase: PASSPHRASE)
  end

  def remove_fake_passbolt
    return unless @passbolt_dir
    ENV["PATH"] = @previous_path
    Rails.application.config.x.passbolt.replace(@previous_passbolt)
    FileUtils.rm_rf(@passbolt_dir)
  end

  def passbolt_calls = File.exist?(@passbolt_calls) ? File.read(@passbolt_calls) : ""

  # Which Passbolt user each call ran as, by a digest of its key and
  # passphrase, so a test can tell users apart without the secret in the record.
  def passbolt_users = passbolt_calls.lines.grep(/^USER /).map { it.split.last }

  def passbolt_user(private_key, passphrase) = Digest::SHA256.hexdigest("#{private_key}|#{passphrase}").first(16)

  # From now on passbolt-save records its call and fails, as one that could
  # not reach the server would.
  def fail_passbolt_save!
    path = File.join(@passbolt_dir, "passbolt-save")
    File.write(path, File.read(path).sub("echo '{\"id\":\"9a1\"}'", "exit 1"))
  end
end
