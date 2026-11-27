require "test_helper"
require "tmpdir"
require_relative "../../config/ci/changed_tests"

# What a pull request's bin/ci runs, mapped from its changed files to the
# tests of a small sample repository. Anything not mapped runs everything.
class CiChangedTestsTest < ActiveSupport::TestCase
  setup do
    @root = Pathname(Dir.mktmpdir("changed-tests"))
    {
      "test/models/admission_test.rb" => "Admission.new",
      "test/models/agent_test.rb" => "Agent.new",
      "test/integration/sign_in_test.rb" => "Admission.admits?; read docs/open-routes.md",
      "test/system/smoke_test.rb" => "visit root_path"
    }.each do |path, source|
      @root.join(path).dirname.mkpath
      @root.join(path).write(source)
    end
  end

  teardown { FileUtils.remove_entry(@root) }

  def changes(*paths) = ChangedTests.new(paths, root: @root)

  test "outside a pull request everything runs" do
    all = ChangedTests.new(nil, root: @root)
    assert all.full?
    assert_empty all.rails_tests, "bin/rails test with no files is the whole suite"
    assert all.system? && all.sidecar? && all.forge_wrapper?
  end

  test "a docs-only change runs the safety nets and no suite" do
    @root.join("test/standards_test.rb").write("")
    docs = changes("docs/agent.md", "README.md")
    assert_not docs.full?
    assert_equal [ "test/standards_test.rb" ], docs.rails_tests, "only the safety nets that exist"
    assert_not docs.system? || docs.sidecar? || docs.forge_wrapper?
  end

  test "a doc a test reads runs that test" do
    assert_equal [ "test/integration/sign_in_test.rb" ], changes("docs/open-routes.md").rails_tests
  end

  test "a model runs its own test and the tests that name it, and no browser tests" do
    model = changes("app/models/admission.rb")
    assert_not model.full?
    assert_equal %w[test/models/admission_test.rb test/integration/sign_in_test.rb].sort, model.rails_tests.sort
    assert_not model.system?
  end

  test "a changed test runs itself, a deleted one nothing, and a browser test the browser suite" do
    assert_equal [ "test/models/agent_test.rb" ], changes("test/models/agent_test.rb").rails_tests
    assert_empty changes("test/models/gone_test.rb").rails_tests
    assert_not changes("test/models/gone_test.rb").full?
    browser = changes("test/system/smoke_test.rb")
    assert browser.system?
    assert_empty browser.rails_tests
  end

  test "a view runs the browser suite and the page tests" do
    view = changes("app/views/agents/show.html.erb")
    assert view.system?
    assert_equal [ "test/integration" ], view.rails_tests
  end

  test "the sidecar and the forge wrapper run their own suites" do
    assert changes("agent/browser.mjs").sidecar?
    assert changes("forge_wrapper/protocol.py").forge_wrapper?
    assert_not changes("agent/browser.mjs").system?
  end

  test "a shared file, or one nothing maps, runs everything" do
    %w[Gemfile.lock config/routes.rb config/ci.rb db/schema.rb test/test_helper.rb .github/workflows/ci.yml bin/ci
       Dockerfile.agent agent/package.json agent/guest/server.js app/models/application_record.rb
       LICENSE app/models/unnamed.rb lib/durable_assistants/unnamed.rb].each do |path|
      assert changes("docs/agent.md", path).full?, "#{path} should run everything"
    end
  end

  test "changes that cannot be listed run everything" do
    system("git", "init", "-q", @root.to_s, exception: true)
    assert ChangedTests.since("0" * 40, root: @root).full?
    assert ChangedTests.since("", root: @root).full?
  end
end
