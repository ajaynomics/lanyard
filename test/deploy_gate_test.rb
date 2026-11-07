require "test_helper"
require "open3"
require "fileutils"
require "tmpdir"
require "shellwords"

# The scripts a deploy runs, executed rather than parsed: the two Kamal hooks
# and the image's entrypoint. Every case runs the real script in a sandbox
# whose bin/kamal is a stub, so the assertions see the script's own decisions
# -- exit status, stderr, and whether it went on to call anything -- instead
# of grepping prose at it.
#
# Why behavioural: the failure modes here are quiet and expensive. Kamal fires
# pre-deploy only after it has built and pushed, and rollback fires it too,
# exporting KAMAL_COMMAND from its hook tags (kamal-2.12.0 lib/kamal/tags.rb).
# A gate that forgot either fact would waste a full build before refusing, or
# lock an emergency rollback behind a shell variable. A failed $(command) in
# .kamal/secrets.<destination> resolves to "" and Kamal deploys on regardless,
# so pre-deploy is the only thing between a Passbolt hiccup and a container
# that boots without its key.
class DeployGateTest < ActiveSupport::TestCase
  HOOKS = %w[pre-build pre-deploy].freeze
  ENTRYPOINT = Rails.root.join("bin/docker-entrypoint")

  # Destinations written into each sandbox, so the gate is tested on its own
  # rule rather than on whichever destinations an install has.
  EXPRESS = "TEST_PRODUCTION_EXPRESS".freeze
  DESTINATIONS = { "staging" => "", "production" => "x-express: #{EXPRESS}\n" }.freeze

  setup do
    @sandbox = Dir.mktmpdir("deploy-gate")
    FileUtils.mkdir_p(File.join(@sandbox, "bin"))
    write_destinations(@sandbox)
    stub_secrets_print("KAMAL_REGISTRY_PASSWORD=unused")
  end

  teardown do
    FileUtils.remove_entry(@sandbox)
  end

  test "a bare express-only deploy is refused before anything builds" do
    _out, stderr, status = run_hook("pre-build",
      "KAMAL_DESTINATION" => "production", "KAMAL_COMMAND" => "deploy")

    assert_equal 1, status.exitstatus, stderr
    assert_includes stderr, "#{EXPRESS}=1 bin/kamal deploy -d production", "the refusal must show the express escape hatch"
  end

  test "pre-deploy refuses an express-only destination without resolving any secret" do
    _out, stderr, status = run_hook("pre-deploy",
      "KAMAL_DESTINATION" => "production", "KAMAL_COMMAND" => "deploy")

    assert_equal 1, status.exitstatus, stderr
    assert_not File.exist?(File.join(@sandbox, "calls.log")),
      "bin/kamal ran during a refused deploy -- credential lookups are work an " \
      "unauthorized release should never trigger"
  end

  test "the express flag admits an express-only destination through both gates" do
    HOOKS.each do |hook|
      _out, stderr, status = run_hook(hook,
        "KAMAL_DESTINATION" => "production", "KAMAL_COMMAND" => "deploy", EXPRESS => "1")

      assert_equal 0, status.exitstatus, "#{hook} refused an expressed release: #{stderr}"
    end
  end

  test "any other value of the flag is still a refusal" do
    HOOKS.each do |hook|
      _out, stderr, status = run_hook(hook,
        "KAMAL_DESTINATION" => "production", "KAMAL_COMMAND" => "deploy", EXPRESS => "yes")

      assert_equal 1, status.exitstatus, "#{hook} took #{EXPRESS}=yes for an express release: #{stderr}"
    end
  end

  test "rollback stays ungated for an express-only destination" do
    # pre-deploy is the only one of the two hooks rollback fires; pin both
    # anyway so exempting rollback in a future edit cannot strand half a rule.
    HOOKS.each do |hook|
      _out, stderr, status = run_hook(hook,
        "KAMAL_DESTINATION" => "production", "KAMAL_COMMAND" => "rollback")

      assert_equal 0, status.exitstatus,
        "#{hook} gated a rollback -- undoing a bad release is exactly when friction is wrong: #{stderr}"
    end
  end

  test "a destination that names no express variable deploys with no flag required" do
    HOOKS.each do |hook|
      _out, stderr, status = run_hook(hook, "KAMAL_DESTINATION" => "staging", "KAMAL_COMMAND" => "deploy")

      assert_equal 0, status.exitstatus, "#{hook} grew a side effect on an everyday destination: #{stderr}"
      assert_no_match(/express/i, stderr)
    end
  end

  test "a blank resolved secret refuses the deploy on every destination" do
    { "staging" => {}, "production" => { EXPRESS => "1" } }.each do |destination, extra|
      _out, stderr, status = run_hook("pre-deploy", {
        "KAMAL_DESTINATION" => destination, "KAMAL_COMMAND" => "deploy"
      }.merge(extra), secrets: [ "KAMAL_REGISTRY_PASSWORD=unused", "SOME_API_KEY=", "RAILS_MASTER_KEY=hunter2" ])

      assert_equal 1, status.exitstatus, "#{destination} deployed with a blank secret: #{stderr}"
      assert_match(/blank secrets: SOME_API_KEY/, stderr, "the refusal must name the blank")
      assert_no_match(/hunter2|unused/, stderr, "the refusal names blanks; it must never print a value")
    end
  end

  test "a value that itself contains an equals sign is not a blank" do
    # OTEL_EXPORTER_OTLP_HEADERS is `Authorization=Bearer <token>`.
    _out, stderr, status = run_hook("pre-deploy", { "KAMAL_DESTINATION" => "staging", "KAMAL_COMMAND" => "deploy" },
      secrets: [ "OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer abc" ])

    assert_equal 0, status.exitstatus, stderr
  end

  # A secrets file may wrap the Passbolt lookup in fixed text, so a
  # failed lookup leaves a line that is not blank and a header carrying no
  # token. The collector answers that with a 401 on every span, which nothing
  # in the deploy would notice.
  test "a bearer header whose token resolved blank is a blank" do
    [ "Authorization=Bearer ", "Authorization=Bearer", "Authorization=Bearer null" ].each do |header|
      _out, stderr, status = run_hook("pre-deploy", { "KAMAL_DESTINATION" => "staging", "KAMAL_COMMAND" => "deploy" },
        secrets: [ "RAILS_MASTER_KEY=hunter2", "OTEL_EXPORTER_OTLP_HEADERS=#{header}" ])

      assert_equal 1, status.exitstatus, "deployed with #{header.inspect}: #{stderr}"
      assert_match(/blank secrets: OTEL_EXPORTER_OTLP_HEADERS/, stderr)
      assert_no_match(/hunter2/, stderr)
    end
  end

  test "a value jq printed for a missing field is a blank" do
    _out, stderr, status = run_hook("pre-deploy", { "KAMAL_DESTINATION" => "staging", "KAMAL_COMMAND" => "deploy" },
      secrets: [ "SOME_API_KEY=null" ])

    assert_equal 1, status.exitstatus, stderr
    assert_match(/blank secrets: SOME_API_KEY/, stderr)
  end

  test "unresolvable secrets refuse the deploy rather than reading as no blanks" do
    write_executable(File.join(@sandbox, "bin", "kamal"), "#!/bin/sh\nexit 1\n")

    _out, stderr, status = run_hook("pre-deploy", "KAMAL_DESTINATION" => "staging", "KAMAL_COMMAND" => "deploy")

    assert_equal 1, status.exitstatus
    assert_match(/could not resolve \.kamal\/secrets\.staging/, stderr)
  end

  # The exemption is for the express flag only: a rollback that boots a
  # container without its key is no recovery.
  test "rollback is exempt from the express flag but not from the blank-secret refusal" do
    _out, stderr, status = run_hook("pre-deploy",
      { "KAMAL_DESTINATION" => "production", "KAMAL_COMMAND" => "rollback" },
      secrets: [ "RAILS_MASTER_KEY=" ])

    assert_equal 1, status.exitstatus, stderr
    assert_match(/blank secrets: RAILS_MASTER_KEY/, stderr)
  end

  # Kamal 2.12 reads hooks from .kamal/hooks and runs any executable it finds
  # there by its bare name. Sample files are inert only because of their
  # suffix; committed, they read like policy that is not, and the two gate
  # hooks are the whole of it.
  test "the hooks directory holds exactly the two gate hooks, executable, and no samples" do
    hooks = Dir[Rails.root.join(".kamal/hooks/*").to_s].map { |path| File.basename(path) }.sort

    assert_equal HOOKS, hooks, "unexpected files in .kamal/hooks (a *.sample is the usual culprit)"
    HOOKS.each do |hook|
      assert File.executable?(Rails.root.join(".kamal/hooks/#{hook}")), "#{hook} is not executable, so Kamal skips it silently"
    end
  end

  test "the missing-destination refusal still stands in front of the gate" do
    _out, stderr, status = run_hook("pre-deploy", "KAMAL_COMMAND" => "deploy")

    assert_equal 1, status.exitstatus, stderr
    assert_match(/KAMAL_DESTINATION is required/, stderr)
  end

  test "pre-build refuses a build with no destination, or one with no file" do
    [ {}, { "KAMAL_DESTINATION" => "mars" } ].each do |variables|
      _out, stderr, status = run_hook("pre-build", variables.merge("KAMAL_COMMAND" => "deploy"))

      assert_equal 1, status.exitstatus, "#{variables}: #{stderr}"
    end
  end

  test "this repository's own destinations pass pre-build with their express flags" do
    Dir[Rails.root.join("config/deploy.*.yml").to_s].each do |path|
      destination = File.basename(path)[/deploy\.(.+)\.yml/, 1]
      express = File.read(path)[/^x-express:\s*(\w+)\s*$/, 1]
      FileUtils.cp(path, File.join(@sandbox, "config"))

      _out, stderr, status = run_hook("pre-build",
        { "KAMAL_DESTINATION" => destination, "KAMAL_COMMAND" => "deploy" }.merge(express ? { express => "1" } : {}))

      assert_equal 0, status.exitstatus, "pre-build refused #{destination}: #{stderr}"
    end
  end

  # Kamal keeps its build clone between deploys and brings it forward with
  # `fetch origin` + `reset --hard <sha>`. Cloning a local path copies
  # refs/heads and not refs/remotes, so a detached HEAD names the commit to
  # nothing the fetch can see and Kamal answers "Could not parse object",
  # deletes the clone and re-clones. Correct, and about a second -- but an
  # ERROR that is not one, on every deploy from a worktree, teaches people to
  # read past errors.
  test "a detached HEAD is explained before the clone, and does not stop the build" do
    @chdir = git_sandbox(detached: true)

    _out, stderr, status = run_hook("pre-build", "KAMAL_DESTINATION" => "staging")

    assert_equal 0, status.exitstatus,
      "the re-clone recovers and the image is built from this commit, so refusing here " \
      "would add friction to a legitimate deploy of a named commit"
    assert_match(/HEAD is detached/, stderr)
    assert_match(/Error preparing clone/, stderr,
      "the warning has to quote the error it is explaining, or it explains nothing")
  end

  test "a branch checkout says nothing about detachment" do
    @chdir = git_sandbox(detached: false)

    _out, stderr, status = run_hook("pre-build", "KAMAL_DESTINATION" => "staging")

    assert_equal 0, status.exitstatus, stderr
    assert_no_match(/detached/, stderr)
  end

  # Outside a repository there is nothing to be detached from, and the same
  # symbolic-ref failure means something else entirely. A warning there would be
  # noise about noise.
  test "outside a git repository the hook says nothing about detachment" do
    _out, stderr, status = run_hook("pre-build", "KAMAL_DESTINATION" => "staging")

    assert_equal 0, status.exitstatus, stderr
    assert_no_match(/detached/, stderr)
  end

  test "the entrypoint prepares the database for the Falcon server command" do
    assert_prepares_database("./bin/falcon")
  end

  # A one-off jobs run reuses the image without migrating: the web container
  # beside it already owns that.
  test "the entrypoint leaves the database alone for anything but Falcon" do
    sandbox_binaries do |directory, calls|
      write_executable(File.join(directory, "bin", "jobs"), "#!/bin/sh\nexit 0\n")

      _output, error, status = Open3.capture3(ENTRYPOINT.to_s, "bin/jobs", chdir: directory)

      assert status.success?, error
      assert_not File.exist?(calls),
        "a jobs run triggered db:prepare; it would race the web container's migration"
    end
  end

  private
    def write_destinations(directory)
      FileUtils.mkdir_p(File.join(directory, "config"))
      DESTINATIONS.each do |destination, header|
        File.write(File.join(directory, "config", "deploy.#{destination}.yml"), "#{header}servers:\n  web:\n    hosts:\n      - example\n")
      end
    end

    # A real repository, because the hook asks git and a stub would only pin the
    # stub. One commit is enough to have a branch and something to detach onto.
    def git_sandbox(detached:)
      repo = File.join(@sandbox, "repo")
      FileUtils.mkdir_p(repo)
      quiet = { chdir: repo, out: File::NULL, err: File::NULL }
      system("git", "init", "-q", "-b", "main", **quiet)
      system("git", "-c", "user.email=t@example.com", "-c", "user.name=T",
             "commit", "-q", "--allow-empty", "-m", "one", **quiet)
      system("git", "checkout", "-q", "--detach", "HEAD", **quiet) if detached
      write_destinations(repo)
      repo
    end

    # What `bin/kamal secrets print` answers with, and a log of the fact it was
    # asked at all.
    def stub_secrets_print(*lines)
      write_executable(File.join(@sandbox, "bin", "kamal"), <<~SH)
        #!/bin/sh
        echo "kamal $*" >> #{File.join(@sandbox, "calls.log").shellescape}
        printf '%s\\n' #{lines.map(&:shellescape).join(" ")}
      SH
    end

    # A minimal environment, not an inherited one: a developer shell carrying
    # the express variable would silently turn every refusal case into a pass,
    # which is precisely the bug class this file exists for.
    #
    # Variables arrive as a hash or as bare string keys, which Ruby passes as
    # keywords.
    def run_hook(hook, variables = {}, secrets: nil, **keywords)
      stub_secrets_print(*secrets) if secrets
      env = {
        "PATH" => "#{File.join(@sandbox, 'bin')}:#{ENV.fetch('PATH', nil)}",
        "HOME" => ENV.fetch("HOME", nil)
      }.merge(variables).merge(keywords)

      Open3.capture3(env, Rails.root.join(".kamal/hooks/#{hook}").to_s, chdir: @chdir || @sandbox)
    end

    def assert_prepares_database(*command)
      sandbox_binaries do |directory, calls|
        _output, error, status = Open3.capture3(ENTRYPOINT.to_s, *command, chdir: directory)

        assert status.success?, error
        assert_equal "db:prepare", File.readlines(calls, chomp: true).first
      end
    end

    # A directory holding the binaries the entrypoint reaches for by relative
    # path, and the file the stubbed bin/rails records its arguments in.
    def sandbox_binaries
      Dir.mktmpdir("entrypoint") do |directory|
        FileUtils.mkdir_p(File.join(directory, "bin"))
        calls = File.join(directory, "calls")
        write_executable(File.join(directory, "bin", "rails"), <<~SH)
          #!/bin/sh
          printf '%s\\n' "$*" >> #{calls.shellescape}
        SH
        # The entrypoint execs the server command after preparing; without
        # this the prepare case would fail on the exec, not the prepare.
        write_executable(File.join(directory, "bin", "falcon"), "#!/bin/sh\nexit 0\n")

        yield directory, calls
      end
    end

    def write_executable(path, contents)
      File.write(path, contents)
      FileUtils.chmod(0o755, path)
    end
end
