require "test_helper"
require "kamal"
require "open3"

# bin/passbolt-fetch resolves a whole .kamal/secrets.<destination> with one
# Passbolt sign-in. A fake `passbolt` on PATH answers with fixture rows and
# records each call; the real Kamal parser reads the secrets file, so this is
# the path a deploy takes, minus the vault.
class PassboltFetchTest < ActiveSupport::TestCase
  HELPER = Rails.root.join("bin/passbolt-fetch").to_s
  A = "11111111-1111-1111-1111-111111111111"
  B = "22222222-2222-2222-2222-222222222222"
  C = "33333333-3333-3333-3333-333333333333"
  ROWS = [
    { id: A, username: "app-user", password: %q(p@ss w'rd "q" \\ ;|&), description: "" },
    { id: B, username: "", password: "crm-app-secret", description: "ENCRYPTION_KEY=enc=key==\r\nPOSTGRES_PASSWORD=db pw;1\nNOTE=x" },
    { id: C, username: "", password: "pp", description: "-----BEGIN KEY-----\nabc\n-----END KEY-----" }
  ].freeze

  test "every field, values composed from others, and exactly one sign-in" do
    with_fake_passbolt do |dir, env|
      secrets = parse(dir, env, <<~SECRETS)
        PASSBOLT=$(#{HELPER} PW=#{A} USER=#{A}:username KEY=#{C}:description ENC=#{B}:description:ENCRYPTION_KEY DB=#{B}:description:POSTGRES_PASSWORD)
        PW=$(kamal secrets extract PW $PASSBOLT)
        USER=$(kamal secrets extract USER $PASSBOLT)
        KEY=$(kamal secrets extract KEY $PASSBOLT)
        ENC=$(kamal secrets extract ENC $PASSBOLT)
        DB=$(kamal secrets extract DB $PASSBOLT)
        URL=postgres://crm:$DB@crm-db:5432/crm
        URL2=postgres://wiki:${DB}@wiki-db:5432/wiki
      SECRETS

      assert_equal %q(p@ss w'rd "q" \\ ;|&), secrets["PW"]
      assert_equal "app-user", secrets["USER"]
      assert_equal "-----BEGIN KEY-----\nabc\n-----END KEY-----", secrets["KEY"]
      assert_equal "enc=key==", secrets["ENC"]
      assert_equal "db pw;1", secrets["DB"]
      assert_equal "postgres://crm:db pw;1@crm-db:5432/crm", secrets["URL"]
      assert_equal "postgres://wiki:db pw;1@wiki-db:5432/wiki", secrets["URL2"]

      calls = File.readlines(File.join(dir, "calls"))
      assert_equal 1, calls.size, "one sign-in for the whole file"
      assert_includes calls.first, %(ID == "#{A}" || ID == "#{B}" || ID == "#{C}")
    end
  end

  test "a failure prints nothing and names the secret, never a value" do
    with_fake_passbolt do |_, env|
      {
        [ "E=#{C}:username" ] => /E: empty/,
        [ "M=#{B}:description:MISSING" ] => /MISSING= is not on exactly one/,
        [ "N=#{A}:secret" ] => /bad argument for N/,
        [ "lower=#{A}" ] => /bad argument/,
        [ "N=not-a-uuid" ] => /bad argument/,
        [ "N=#{A}:password:K" ] => /bad argument/,
        [ "N=#{B}:description:K:EXTRA" ] => /bad argument/,
        [] => /nothing to fetch/
      }.each do |args, message|
        stdout, stderr, status = Open3.capture3(env, HELPER, *args)
        assert_equal "", stdout, args.inspect
        assert_not status.success?, args.inspect
        assert_match message, stderr
        assert_no_match(/crm-app-secret|db pw|p@ss|enc=key/, stderr)
      end
    end

    with_fake_passbolt(ROWS + [ { id: B, password: "duplicate" } ]) do |_, env|
      stdout, stderr, status = Open3.capture3(env, HELPER, "X=#{B}")
      assert_equal [ "", false ], [ stdout, status.success? ]
      assert_match(/X: resource not found exactly once/, stderr)
    end

    with_fake_passbolt([ { id: B, description: "K=first\nK=second" } ]) do |_, env|
      stdout, stderr, status = Open3.capture3(env, HELPER, "K=#{B}:description:K")
      assert_equal [ "", false ], [ stdout, status.success? ]
      assert_no_match(/first|second/, stderr)
    end
  end

  # S9 passes the whole bundle to `kamal secrets extract`, which looks like a
  # process argument but is not: Kamal runs that command inside its own
  # process (Kamal::Secrets::Dotenv::InlineCommandSubstitution). Any other
  # $(...) goes to a shell with its variables already written in, so "pipe it
  # on stdin instead" would put every secret on the shell's command line. This
  # records every command Kamal hands to a shell and looks for a canary.
  test "no secret reaches a command line: extract runs in-process, and a stdin pipe would not" do
    canary = "canary-#{SecureRandom.hex(8)}"
    with_fake_passbolt([ { id: A, password: canary } ]) do |dir, env|
      shelled = spying_on_shells do
        assert_equal canary, parse(dir, env, "PASSBOLT=$(#{HELPER} PW=#{A})\nPW=$(kamal secrets extract PW $PASSBOLT)\n")["PW"]
      end
      assert_equal [ "#{HELPER} PW=#{A}" ], shelled, "only the fetch, which names resource ids, runs in a shell"

      shelled = spying_on_shells do
        parse(dir, env, "PASSBOLT=$(#{HELPER} PW=#{A})\nPW=$(printf '%s' \"$PASSBOLT\" | cat)\n")
      end
      assert shelled.any? { it.include?(canary) }, "a stdin pipe writes the bundle into the shell's command line"
    end
  end

  test "Kamal stops instead of deploying a blank when the fetch fails" do
    with_fake_passbolt([]) do |dir, env|
      assert_raises(SystemExit) do
        capture_io { parse(dir, env, "PASSBOLT=$(#{HELPER} PW=#{A} 2>/dev/null)\nPW=$(kamal secrets extract PW $PASSBOLT)\n") }
      end
    end
  end

  private
    def with_fake_passbolt(rows = ROWS)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "rows.json"), JSON.dump(rows))
        File.write(File.join(dir, "passbolt"), "#!/bin/sh\necho \"$@\" >> #{dir}/calls\ncat #{dir}/rows.json\n")
        File.chmod(0o700, File.join(dir, "passbolt"))
        yield dir, { "PATH" => "#{dir}:#{ENV.fetch("PATH")}" }
      end
    end

    def spying_on_shells
      shelled = []
      substitution = Kamal::Secrets::Dotenv::InlineCommandSubstitution
      substitution.singleton_class.define_method(:`) { |command| shelled << command; super(command) }
      yield
      shelled
    ensure
      substitution.singleton_class.remove_method(:`)
    end

    def parse(dir, env, body)
      path = File.join(dir, "secrets")
      File.write(path, body)
      saved = ENV.to_h
      ENV.update(env)
      Kamal::Secrets.new(secrets_path: path).to_h
    ensure
      ENV.replace(saved)
    end
end
