require "test_helper"

# Records owned by an organization or a user are reached through their owner,
# never globally, and never through default_scope, which leaks through
# unscoped, joins, and jobs that run without a Current. A convention alone will
# not hold; this test is the enforcement (STANDARDS.md S7).
#
# It fails on any bare `Model.find` / `find_by` / `where` / ... against an
# owned model, or one reached through one, in a controller, job, model or
# helper. Those go through the owner (current_user.things.find,
# Current.organization.things) or a record already reached that way, so an id
# from another owner is not found.
#
# A query that is genuinely global opts out with a reason on the same line:
#
#   Run.where(status: "streaming") # tenancy-ok: the reaper sweeps every owner's runs
#
# To adopt it in an app: set OWNER_COLUMN and list the models below. The lists
# start empty because a new app has no records; every model added later has to
# be placed in one of them, which is the point.
class TenancyScopingTest < ActiveSupport::TestCase
  # The column that makes a record owned: "user_id" or "organization_id".
  OWNER_COLUMN = "user_id".freeze

  # Records that carry OWNER_COLUMN.
  OWNED_MODELS = %w[
    Bot Conversation
  ].freeze

  # The owner model itself when it is a tenant (Organization): it has no
  # OWNER_COLUMN, but reaching it unscoped is reaching every tenant.
  TENANT_ROOTS = %w[
    User
  ].freeze

  # No OWNER_COLUMN of their own: each belongs to an owned record, so reaching
  # one is reaching that owner's records. Scanned all the same.
  REACHED_THROUGH_OWNER = %w[
    Bot::Revision Note Invocation Approval Answer Message
  ].freeze

  # Deliberately not owned, each with the reason beside it.
  GLOBAL_MODELS = %w[
  ].freeze

  # Jobs that take a record (as a GlobalID) rather than an id are scoped by
  # construction. A job with no arguments is a sweep over everyone's records
  # and must be named here and say "deliberately global" in its source.
  GLOBAL_SWEEPS = %w[
  ].freeze

  UNSCOPED_CALLS = %w[
    find find_by find_by! where all first last count exists?
    find_or_create_by find_or_create_by! find_or_initialize_by
    sole take pluck pick select find_signed find_signed! update_all delete_all destroy_all
    insert_all insert_all! upsert_all
  ].freeze

  SCANNED_GLOBS = [
    "app/controllers/**/*.rb",
    "app/helpers/**/*.rb",
    "app/jobs/**/*.rb",
    "app/models/**/*.rb"
  ].freeze

  OPT_OUT = /#\s*tenancy-ok:\s*\S/

  test "nothing reaches an owned record globally" do
    offenses = scan_for_offenses

    assert_empty offenses, <<~MESSAGE
      Unscoped access to owned models:

      #{offenses.join("\n")}

      Reach these through the owner or a record already inside one. If the
      query is genuinely global, append "# tenancy-ok: <reason>" to the line.
    MESSAGE
  end

  test "no model declares default_scope" do
    offenders = Rails.root.glob("app/models/**/*.rb").select { |path| path.read.match?(/^\s*default_scope\b/) }

    assert_empty offenders.map(&:to_s), "default_scope leaks through unscoped, joins, and jobs; scope through associations"
  end

  test "every record is owned, reached through an owner, or deliberately global" do
    with_owner, without_owner = application_records.partition { |klass| klass.column_names.include?(OWNER_COLUMN) }
    owned = with_owner.reject { |klass| GLOBAL_MODELS.include?(klass.name) }

    assert_equal OWNED_MODELS.sort, owned.map(&:name).sort,
      "A record with #{OWNER_COLUMN} belongs in OWNED_MODELS, or in GLOBAL_MODELS with a reason"
    assert_equal (REACHED_THROUGH_OWNER + GLOBAL_MODELS + TENANT_ROOTS).sort, (without_owner + (with_owner - owned)).map(&:name).sort,
      "A new record without #{OWNER_COLUMN} must say how it reaches an owner, or why it is global"

    owned.each do |klass|
      assert_not klass.columns_hash[OWNER_COLUMN].null, "#{klass.name}.#{OWNER_COLUMN} must be NOT NULL"
    end
  end

  test "a record reached through an owner cannot exist without one" do
    scanned = OWNED_MODELS + REACHED_THROUGH_OWNER

    REACHED_THROUGH_OWNER.each do |name|
      parents = name.constantize.reflect_on_all_associations(:belongs_to).reject { |reflection| reflection.options[:optional] }

      assert parents.any? { |reflection| scanned.include?(reflection.klass.name) },
        "#{name} needs a required belongs_to to an owned record"
    end
    pass if REACHED_THROUGH_OWNER.empty? # nothing to check until the first record is added
  end

  test "every job takes the record it works on, or is a named global sweep" do
    sweeps, record_jobs = app_jobs.partition { |job| required_perform_arguments(job).empty? }

    assert_equal GLOBAL_SWEEPS.sort, sweeps.map(&:name).sort,
      "A new job without arguments joins GLOBAL_SWEEPS and says why"

    # A record crosses the queue as its GlobalID: the worker finds that row and
    # no other, owner and all. A bare id would be looked up again, unscoped.
    models = application_records.map { |klass| klass.model_name.element }
    record_jobs.each do |job|
      first = required_perform_arguments(job).first
      assert_includes models, first, "#{job.name}#perform takes #{first}; pass the record, not its id"
    end
  end

  test "global sweeps say they are deliberately global" do
    GLOBAL_SWEEPS.each do |name|
      assert_match(/deliberately global/i, Rails.root.join("app/jobs/#{name.underscore}.rb").read, name)
    end
    pass if GLOBAL_SWEEPS.empty? # nothing to check until the first sweep is added
  end

  test "the scan detects a violation" do
    models = %w[Trip Trip::Reading]

    assert_equal 1, offenses_in("app/controllers/fake_controller.rb", "    @trip = Trip.find(params[:id])\n", models).size
    assert_equal 1, offenses_in("app/models/fake.rb", "    Trip::Reading.where(trip_id: id)\n", models).size
    assert_equal 1, offenses_in("app/models/fake.rb", "    Trip.exists?(id)\n", models).size
    assert_equal 1, offenses_in("app/models/fake.rb", "    Trip.find_by_slug(id)\n", models).size
    assert_equal 1, offenses_in("app/models/fake.rb", "    Trip.pick(:id) # tenancy-ok:\n", models).size, "an opt-out needs a reason"

    assert_empty offenses_in("app/controllers/fake_controller.rb", "    current_user.trips.find(params[:id])\n", models)
    assert_empty offenses_in("app/models/fake.rb", "    Trip.where(x: 1) # tenancy-ok: a reason\n", models)
    assert_empty offenses_in("app/models/fake.rb", "    # Trip.find(id) in a comment\n", models)
    assert_empty offenses_in("app/models/fake.rb", "    Trip::Extractor.for(kind)\n", models)
  end

  private
    def application_records
      Rails.application.eager_load!
      ApplicationRecord.descendants.reject { |klass| klass.abstract_class? || klass.name.blank? }
    end

    def app_jobs
      Rails.application.eager_load!
      root = Rails.root.join("app/jobs").to_s
      ApplicationJob.descendants.select { |job| job.instance_method(:perform).source_location&.first&.start_with?(root) }
    end

    def required_perform_arguments(job)
      job.instance_method(:perform).parameters.filter_map { |type, name| name.to_s if type == :req }
    end

    def scan_for_offenses
      SCANNED_GLOBS.flat_map { |glob| Rails.root.glob(glob) }.flat_map do |path|
        offenses_in(path.relative_path_from(Rails.root).to_s, path.read, OWNED_MODELS + TENANT_ROOTS + REACHED_THROUGH_OWNER)
      end
    end

    # Longest names first, so Trip::Reading is caught whole rather than read as
    # Trip. The lookbehind keeps Foo::Trip from counting as Trip; the lookahead
    # stands in for \b, which never matches after `?`, and keeps a bare find_by
    # from matching inside a dynamic finder, caught whole. With no models the
    # union matches nothing.
    def offenses_in(relative_path, source, models)
      pattern = /(?<![\w:])(#{Regexp.union(models.sort_by { |name| -name.length })})\.(#{Regexp.union(UNSCOPED_CALLS)}(?![\w?!])|find_by_\w+)/

      source.lines.each_with_index.filter_map do |line, index|
        next if line.match?(OPT_OUT) || line.strip.start_with?("#")
        next unless line.match?(pattern)

        "  #{relative_path}:#{index + 1}  #{line.strip}"
      end
    end
end
