# A stand-in `passbolt` command on PATH, so lib/durable_assistants/passbolt.rb
# runs for real: it records each call's arguments and environment, and prints
# one shared sign-in, as go-passbolt-cli's --json does.
module PassboltTestHelper
  PASSWORD = "correct-horse-battery-staple-7731"
  PRIVATE_KEY = "-----BEGIN PGP PRIVATE KEY BLOCK-----\nsynthetic\n-----END PGP PRIVATE KEY BLOCK-----"
  PASSPHRASE = "synthetic-passphrase-for-the-agents"

  def install_fake_passbolt(fail: false)
    @passbolt_dir = Dir.mktmpdir("fake-passbolt")
    @passbolt_calls = File.join(@passbolt_dir, "calls")
    listed = [ { id: "7f0c", name: "Bank", uri: "https://bank.example/login" } ].to_json
    entry = { name: "Bank", uri: "https://bank.example/login", username: "maya", password: PASSWORD }.to_json
    File.write(File.join(@passbolt_dir, "passbolt"), <<~SH)
      #!/bin/sh
      { echo "ARGS $*"; env | grep -E '^(SERVERADDRESS|USERPRIVATEKEY|USERPASSWORD|XDG_CONFIG_HOME)=' | cut -d= -f1; } >> #{@passbolt_calls}
      #{fail ? "echo 'boom #{PASSWORD}' >&2; exit 1" : ""}
      case "$1 $2" in
        "list resource") echo '#{listed}' ;;
        "get resource") echo '#{entry}' ;;
      esac
    SH
    File.chmod(0o755, File.join(@passbolt_dir, "passbolt"))
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
end
