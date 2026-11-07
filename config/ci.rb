# Run using bin/ci. This is the whole contract (STANDARDS.md S5): CI runs
# exactly `bin/ci` and nothing else, so a check that is not a step here does
# not exist, and a step here runs in CI without touching the workflow.

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

  step "Tests: Rails", "bin/rails test"

  # Not optional: browser tests are part of the contract, and CI sets up Chrome
  # for them. Leaving this out is how `bin/ci` says green while main is red.
  # Its own step, never folded into "Tests: Rails": `bin/rails test test/`
  # would pull test/system into that parallelized run.
  step "Tests: System", "bin/rails test:system"
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant"

  # Production initializers only take their configured branches when a secret
  # is present (a GlitchTip DSN, for instance), which no test sets. Booting the
  # production environment with one catches a boot failure before a deploy's
  # health check does. SECRET_KEY_BASE_DUMMY skips the required-secrets check
  # in config/initializers/production_secrets.rb, so the fakes below are only
  # what the branches under test read.
  step "Boot: production", "env RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 GLITCHTIP__DSN=https://key@glitchtip.invalid/1 APP__URL=https://assistants.example.com bin/rails runner 'abort(\"GlitchTip not initialized\") unless Sentry.initialized?'"

  # App-specific steps (another runtime's tests, a conformance suite) go here.
  step "Tests: Agent sidecar", "bin/agent-test"
end
