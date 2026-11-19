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
  # Stopgap while the flaky browser tests are fixed (#61, fix/settings-test-races):
  # a failed system test is retried once and printed as FLAKY. Back to plain
  # `bin/rails test:system` once they are gone.
  # A run takes about five minutes in CI; one still going after twenty has
  # hung, and is stopped with a message rather than left to the job's limit.
  step "Tests: System", "bin/retry-system-tests --minutes 20 bin/rails test:system"
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
  step "Tests: Agent sidecar", "bin/agent-test"

  # The agent's computer image as built: its secrets out of the agent's reach,
  # each process as its own user, the screen and commands working (#58). It
  # needs Docker, which CI's runner has; publish also runs it on the image it
  # pushes, so no image goes out unchecked where this step could not run.
  if system("docker", "info", out: File::NULL, err: File::NULL)
    step "Tests: Computer image", "bin/check-computer-image"
  else
    puts "Tests: Computer image not run here: no Docker (publish runs bin/check-computer-image on the image it pushes)"
  end
end
