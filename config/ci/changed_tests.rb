require "open3"
require "pathname"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/inflections"

# Which tests a pull request needs, for bin/ci (config/ci.rb). Outside a pull
# request everything runs. In one, the lint and security checks always run,
# with a few cheap safety nets, plus the tests the changed files map to. It
# fails closed: a file nothing maps, or one every test shares, runs
# everything. Only docs may map to no test at all.
class ChangedTests
  SAFETY_NETS = %w[
    test/standards_test.rb
    test/env_example_test.rb
    test/tenancy_scoping_test.rb
    test/integration/cross_workspace_leak_test.rb
  ].freeze

  # Shared by every test, or built into an image only the full run checks.
  EVERYTHING = %r{\A(?:
    Gemfile.* | \.ruby-version | \.github/.* | bin/.* | config/.* | db/.* | lib/tasks/.* | Dockerfile.* |
    agent/package.*\.json | agent/guest/.* | agent/sprite-relay\.mjs |
    app/[^/]+/application_[^/]+ | app/models/current\.rb |
    test/test_helper\.rb | test/application_system_test_case\.rb | test/test_helpers/.*
  )\z}x
  DOCS = %r{\A(?:docs/.*|(?!app/).*\.md)\z}
  PAGES = %r{\Aapp/(?:views|helpers|javascript|assets)/}
  PAGE_TESTS = %w[test/controllers test/integration test/views test/helpers].freeze

  # The files changed since base (the pull request's target), or nil, and so
  # everything, when base is not given or git cannot compare against it.
  def self.since(base, root: Dir.pwd)
    return new(nil, root:) if base.blank?

    out, status = Open3.capture2("git", "diff", "--name-only", "#{base}...HEAD", chdir: root.to_s, err: File::NULL)
    new(status.success? ? out.lines(chomp: true) : nil, root:)
  end

  def initialize(paths, root: Dir.pwd)
    @root = Pathname(root)
    @targets = paths&.to_h { [ it, targets_for(it) ] }
  end

  def full? = @targets.nil? || @targets.value?(nil)

  # Every test when empty: `bin/rails test` with no files.
  def rails_tests
    return [] if full?

    (SAFETY_NETS + targets.grep(String)).uniq.select { @root.join(it).exist? }
  end

  def system? = full? || targets.include?(:system)
  def sidecar? = full? || targets.include?(:sidecar)
  def forge_wrapper? = full? || targets.include?(:forge_wrapper)

  def to_s
    if @targets.nil?
      "Running every check: not a pull request, or its changes could not be listed."
    elsif full?
      "Running every check, for: #{@targets.select { |_, targets| targets.nil? }.keys.join(", ")}"
    else
      "Running the checks #{@targets.size} #{"changed file".pluralize(@targets.size)} touch: #{rails_tests.size} test paths" \
        "#{", the browser suite" if system?}#{", the sidecar suite" if sidecar?}#{", the forge wrapper's" if forge_wrapper?}."
    end
  end

  private
    def targets = @targets.values.flatten

    # nil when nothing maps the path, which runs everything.
    def targets_for(path)
      return if EVERYTHING.match?(path)

      targets = tests_naming(path) + by_kind(path)
      targets if targets.any? || DOCS.match?(path)
    end

    def by_kind(path)
      case path
      when %r{\Atest/system/} then [ :system ]
      when %r{\Atest/.+_test\.rb\z} then [ path ]
      when PAGES then [ :system, *PAGE_TESTS ]
      when %r{\Aapp/([^/]+)/(?:concerns/)?(.+)\.rb\z} then ruby_tests("test/#{$1}/#{$2}_test.rb", $2)
      when %r{\Alib/(.+)\.rb\z} then ruby_tests("test/lib/#{$1}_test.rb", $1) + ruby_tests("test/lib/#{File.basename($1)}_test.rb")
      when %r{\Aagent/} then [ :sidecar ]
      when %r{\Aforge_wrapper/} then [ :forge_wrapper ]
      else []
      end
    end

    def ruby_tests(conventional, name = nil)
      [ conventional ].select { @root.join(it).exist? } + (name ? tests_matching(/\b#{Regexp.escape(name.camelize)}\b/) : [])
    end

    # Tests that read the file by its path, or by its name if it isn't Ruby.
    def tests_naming(path)
      tests_matching(Regexp.union(path, *(File.basename(path) unless path.end_with?(".rb"))))
    end

    def tests_matching(pattern)
      sources.filter_map { |test, source| (test.start_with?("test/system/") ? :system : test) if source.match?(pattern) }
    end

    def sources
      @sources ||= Dir.glob("test/**/*_test.rb", base: @root).to_h { [ it, @root.join(it).read ] }
    end
end
