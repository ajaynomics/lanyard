# Run using bin/ci. This is the whole contract (STANDARDS.md S5): CI runs
# exactly `bin/ci` and nothing else, so a check that is not a step here does
# not exist, and a step here runs in CI without touching the workflow.

# A pull request's run sets CI_CHANGED_FROM to its target's commit. Then the
# style, security and boot checks still all run, but the test suites only
# for what its changed files touch (config/ci/changed_tests.rb), failing
# closed to everything. Without it, as on main, everything runs.
require_relative "ci/changed_tests"
changes = ChangedTests.since(ENV["CI_CHANGED_FROM"])
puts changes

CI.run do
  step "Build context: Core image paths", "python3 bin/check-core-images --source-paths"

  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

  step "Tests: Rails", [ "bin/rails test", *changes.rails_tests ].join(" ")

  # Not optional: browser tests are part of the contract, and CI sets up Chrome
  # for them. Leaving this out is how `bin/ci` says green while main is red.
  # Its own step, never folded into "Tests: Rails": `bin/rails test test/`
  # would pull test/system into that parallelized run.
  # Stopgap while the flaky browser tests are fixed (#61, fix/settings-test-races):
  # a failed system test is retried once and printed as FLAKY. Back to plain
  # `bin/rails test:system` once they are gone.
  # A run takes about five minutes in CI; one still going after twenty has
  # hung, and is stopped with a message rather than left to the job's limit.
  # Quarantined, not fixed: each runs alone in a fresh process and still fails CI if it fails.
  # AgentListTest's two: from 9180. They passed alone on the same code, but CI did not
  # establish why they failed in the shared run.
  # ThreadWaitingTest's: from 9240, on #453, whose diff does not touch approvals or answers.
  # Answer stayed on /approvals/2. Not reproduced in 46 local runs alone or under
  # load, or in a full system run with CI's seed.
  # NativeAppTest's: the approval setup saw the wrong title in CI 9410/1 (#515).
  isolated = {
    "sidebar archive" => [ "agent_list", "AgentListTest", "test_an_agent_that_needs_you_moves_to_the_top,_a_new_one_appears,_an_archived_one_leaves,_and_the_open_one_stays_marked" ],
    "sidebar prefetched read" => [ "agent_list", "AgentListTest", "test_a_thread_opened_by_a_click_after_the_pointer_rested_on_it_is_read,_and_turns_unread_again_only_for_a_new_reply" ],
    "helper answer" => [ "thread_waiting", "ThreadWaitingTest", "test_a_helper.s_question_after_the_agent_finished_is_answered_from_the_line_above_the_box,_and_the_thread_goes_idle,_not_working" ],
    "native approval fallback" => [ "native_app", "NativeAppTest", "test_without_the_approval_or_toast_components_a_card_is_answered_from_the_page,_and_its_flash_shows_there" ]
  }
  if changes.system?
    # The host's disk, recorded beside the browser tests: a warning there is read before a red (bin/io-pressure).
    step "Host: I/O pressure before system tests", "bin/io-pressure 'before system tests'"
    # Whole backtraces, gem frames too: 9456's failure was cut to one frame inside a gem.
    step "Tests: System", "env BACKTRACE=1 bin/retry-system-tests --minutes 20 bin/rails test:system --exclude '/\\A(?:#{isolated.values.map { |_, klass, name| "#{klass}##{name}" }.join('|')})\\z/'"
    isolated.each do |case_name, (file, klass, name)|
      step "Tests: System #{case_name}", "env BACKTRACE=1 bin/rails test test/system/#{file}_test.rb --include '/\\A#{klass}##{name}\\z/'"
    end
    step "Host: I/O pressure after system tests", "bin/io-pressure 'after system tests'"
  end
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant"

  # Production initializers only take their configured branches when a secret
  # is present (a GlitchTip DSN, for instance), which no test sets. Booting the
  # production environment with one catches a boot failure before a deploy's
  # health check does. SECRET_KEY_BASE_DUMMY skips the required-secrets check
  # in config/initializers/production_secrets.rb, so the fakes below are only
  # what the branches under test read.
  step "Boot: production", "env RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 GLITCHTIP__DSN=https://key@glitchtip.invalid/1 APP__URL=https://assistants.example.com bin/rails runner 'abort(\"GlitchTip not initialized\") unless Sentry.initialized?'"
  # And once as a deploy boots: no dummy, so the required-secrets check runs
  # against the real configuration, with every required value set (fakes).
  step "Boot: production, secrets checked", "env RAILS_ENV=production SECRET_KEY_BASE=ci-boot-only APP__URL=https://assistants.example.com " \
    "OIDC__ISSUER=https://id.example.com OIDC__CLIENT_ID=ci OIDC__CLIENT_SECRET=ci bin/rails runner 'abort(\"secrets check skipped\") if ENV[\"SECRET_KEY_BASE_DUMMY\"]'"

  # App-specific steps (another runtime's tests, a conformance suite) go here.
  step "Boot: production, encrypted rows", "bin/boot-check"
  step "Tests: Agent sidecar", "bin/agent-test" if changes.sidecar?
  step "Tests: Host forge wrapper", "env PYTHONPATH=forge_wrapper python3 -B -m unittest discover -s forge_wrapper/tests" if changes.forge_wrapper?

  # The agent's computer image as built: its secrets out of the agent's reach,
  # each process as its own user, the screen and commands working (#58). It
  # needs Docker, which CI's runner has; publish also runs it on the image it
  # pushes, so no image goes out unchecked where this step could not run.
  if !changes.full?
    puts "Tests: Computer image not run for this pull request: none of its changes is built into the image"
  elsif system("docker", "info", out: File::NULL, err: File::NULL)
    step "Tests: Computer image", "bin/check-computer-image"
  else
    puts "Tests: Computer image not run here: no Docker (publish runs bin/check-computer-image on the image it pushes)"
  end
end
