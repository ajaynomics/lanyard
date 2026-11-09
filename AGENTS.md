# Working on Lanyard

For anyone changing this code: a person, a coding agent, or a person driving
one. Read `README.md`, `CONTEXT.md` (the domain's words), `docs/design/PLAN.md`
(the plan of record) and then the code. This file is the rules for changing
it; a rule that stops being true is deleted rather than left standing.
`CONTRIBUTING.md` covers sending a change.

## Setup and tests

```shell
bin/setup --skip-server   # gems and the development database
bin/ci                    # everything CI runs; a change is ready when it passes
bin/rails test test/models/agent_test.rb   # one file
bin/rails test:system     # the browser tests, which need Chromium and chromedriver
(cd agent && npm test)    # the sidecar's own tests
```

`README.md`'s "Run it locally" starts the app. Tests never reach the network
and never read `.env`.

## Where things live

| Path | What |
|---|---|
| `app/models` | The domain. `Conversation` is an agent's thread, `Agent` its settings, `Invocation` the ledger of tool calls, `Approval` and `Permission` a person's answers. |
| `app/models/tool/` | One class per tool an agent may call, with its arguments and whether a person must answer first (`Tool.asks`). |
| `app/models/mcp_server/` | Connectors. `McpServer::Google` holds Gmail, Calendar, Drive and Docs over REST. |
| `lib/durable_assistants/` | Thin clients for outside services (email, CalDAV, voip.ms, Campfire, Concourse, OIDC, Passbolt, the sidecar) and the platform wiring. |
| `app/views`, `app/javascript/controllers` | Turbo Streams and Stimulus. Live updates are broadcast; nothing polls. |
| `agent/` | The Node sidecar that runs agents on Pi Durable (`docs/agent.md`). |
| `config/agents/` | Starter agents, each its own instructions and settings. |
| `docs/` | One page per feature. Change the page with the feature. |

## Do not touch without an issue first

- **Approvals.** What asks a person first, and above all the list that asks
  even where an install approves everything (`McpServer::Google::EVERY_TIME`,
  `Tool.asks` with `even_approving_everything:`), is a safety boundary. Loosen
  nothing there in passing.
- **Secrets.** Never commit, print or log one. Tests use made-up values.
- **Migrations.** Each comes with a test of what it does to existing rows, and
  stays safe across a rolling deploy (below).
- **`test/standards_test.rb` and `test/env_example_test.rb`.** They are a
  shared standard: change the app, not them.

## North star

**Idiomatic omakase Rails. Do what `rails generate` would do.**

- **durable-assistants** is the project: a multi-tenant Rails template in which
  people define, configure and run their own agents (assistants), each
  conversation with its own computer, screen and connectors. It ships as an
  image; each deployment is an install that runs it with its own
  configuration (`docs/deployments.md`). It must never become a service layer around a model: Rails
  holds the logic and the tools, the sidecar only runs them.
- Build what the next user-visible step needs. Anything else waits for a real
  use.

## Rails conventions

Rails 8.2 (edge, pinned) omakase, SQLite, Hotwire, import maps, Propshaft,
Solid Queue / Cache / Cable, Minitest, Kamal, `rubocop-rails-omakase`
unmodified. Falcon serves it, not Puma: a request is a fiber, so a slow upstream
call holds no thread.

- No service layer. Logic lives in models, jobs, and controllers. A thin object
  may isolate an external provider.
- CRUD controllers and REST resources. A custom action becomes a nested
  resource.
- No fixtures, no factories; tests build through model constructors.
- Hotwire, not a single-page app: Turbo Streams for live changes, a small
  Stimulus controller where the page needs one, no polling.
- Small objects. A rule with a name gets its own small class or concern rather
  than a branch in a large one.
- Configuration is `config/<service>.yml`, loaded with `config_for` in
  `config/application.rb` and read with `Rails.app.creds.option(:service, :key)`:
  ENV under Rails' name (`SERVICE__KEY`) first, then encrypted credentials. Read
  through `DurableAssistants.config(*path, default:)`. `.env.example` lists every
  setting, and documents, commented out, every process knob read straight from
  ENV under its Rails or tool name (`JOB_CONCURRENCY`, `RAILS_LOG_LEVEL`,
  `OTEL_*`); those are not settings and never go through credentials.
- `test/standards_test.rb` and `test/env_example_test.rb` are verbatim copies of
  a shared standard (`STANDARDS.md` in the template it started from). Never
  edit them here: change the app instead.
- Comments explain why, never what.
- Migrations stay safe across a rolling deploy: add freely; to remove a column,
  ignore it in the model and deploy before the migration drops it.
- Platform wiring (OIDC sign-in, GlitchTip, OpenTelemetry, Rybbit, Cloudflare
  trusted proxies): `lib/durable_assistants/` holds the app-owned pieces.

## Boundaries the tests enforce

Each boundary names the test that holds it; a boundary with no test is a bug.

- **Falcon, with jobs in their own role.** `gem "falcon"`, `bin/falcon`, the
  image's `CMD ["./bin/falcon"]`, no Puma or Thruster, Solid Queue in a Kamal
  `job` role running `bin/jobs`. The web container migrates on boot.
  (`test/standards_test.rb` S1, `test/production_deploy_config_test.rb`,
  `test/deploy_gate_test.rb`)
- **The shared Rails pin.** One edge SHA, `config.load_defaults 8.2`.
  (`test/standards_test.rb` S2)
- **Settings.** Read through `Rails.app.creds`, never a hand-rolled helper;
  every `creds.option` key is in `.env.example`, nothing stale is, and every
  plain ENV knob is documented there. No `dotenv` gem.
  (`test/standards_test.rb` S3 and S4, `test/env_example_test.rb`,
  `test/config_test.rb`)
- **Production configuration.** A missing app URL, or no complete way to sign
  in (an OIDC client), fails the boot, not a request. GlitchTip is optional. (`test/config_test.rb`)
- **One sign-in door.** Only an OpenID Connect sign-in starts a session, keyed
  by `sub`, for a verified email on the list. If the provider cannot be reached
  nobody new is admitted and people already signed in keep working.
  (`test/integration/ajent_sign_in_test.rb`)
- **Admission on every request.** `Admission.admits?` is asked at sign-in, on
  every request and when a live connection opens, so removing an email ends that
  person's session. (`test/integration/ajent_sign_in_test.rb`,
  `test/channels/application_cable/connection_test.rb`)
- **Nothing is trusted by header.** A Sprite can reach kamal-proxy and write any
  header, so no header, address or origin identifies anyone: the session cookie
  does, and the sidecar's callbacks have their own bearer. Pictures are no
  exception: Active Storage's controllers include `Authentication`
  (`config/initializers/active_storage.rb`), so a picture's link needs the
  sign-in too.
  (`test/integration/forged_identity_test.rb`)
- **Open to the internet.** No Cloudflare Access in front: every route needs a
  signed-in, admitted person or is listed, with its guard, in
  `docs/open-routes.md`. What answers without a session is rate limited
  (`rate_limit`; OmniAuth's routes by `DurableAssistants::SignInLimit`, ahead
  of it). The sidecar's callbacks answer only inside the host: anything
  carrying kamal-proxy's or Cloudflare's headers, or a public name, gets 404,
  whatever its token. A header can only get a request refused, never admitted.
  (`test/integration/open_routes_test.rb`, `test/integration/rate_limits_test.rb`,
  `test/controllers/sidecar/private_callbacks_test.rb`)
- **Telemetry privacy.** The app-owned exporter allowlists operational attributes,
  removes raw URLs, event/link payloads and status descriptions, and normalises
  HTTP names. No endpoint means no SDK configuration. Do not put user content
  in retained labels or resource configuration; extend privacy tests when adding
  instrumentation. (`test/telemetry_privacy_test.rb`)
- **bin/ci is the whole contract.** Rubocop, bundler-audit, importmap audit,
  Brakeman with `--exit-on-warn`, `bin/rails test`, `bin/rails test:system`,
  seeds, and a production boot; CI runs exactly `bin/ci`.
  (`test/standards_test.rb` S5)
- **No network in tests.** WebMock refuses every connection but localhost.
  (`test/standards_test.rb` S6, `test/test_helper.rb`)
- **Tenancy.** Owned records are reached through their owner; `default_scope` is
  banned; a genuinely global query says why with `# tenancy-ok:`. Declare the
  owner models at the top of the test as they are added.
  (`test/tenancy_scoping_test.rb`)
- **Deploy gate.** `.kamal/hooks/pre-build` and `pre-deploy` refuse a deploy that
  names no destination or one with no file, refuse a destination whose file
  says `x-express: <VARIABLE>` unless `<VARIABLE>=1` (rollback exempt), and refuse any
  secret that resolved blank, including an empty bearer token.
  (`test/deploy_gate_test.rb`, which runs the real hooks against a stub
  `bin/kamal`)
- **Deploy config.** Every destination, merged over `config/deploy.yml`, is
  health-checked at `/up`, caps memory with matching swap, runs Solid Queue only
  in a `job` role, names itself in telemetry, derives `config.hosts` from
  `APP__URL`, and resolves every secret it asks for.
  (`test/production_deploy_config_test.rb`)
- **Real client IP.** Requests arrive through a Cloudflare Tunnel, so Rails'
  default trusted proxies are the whole list; Cloudflare's ranges are never
  trusted. (`test/trusted_proxies_test.rb`, `test/standards_test.rb` S10)
- **Backups.** The real backup script snapshots every production database and
  the real restore script brings them back and verifies them.
  (`test/backup_test.rb`; see `ops/backup/README.md`). The office's backup
  script reads every office accessory that keeps data and publishes nothing
  unchecked. (`test/office_backup_test.rb`)
- **Docs.** `AGENTS.md`, `CONTEXT.md` and `README.md` exist and are not stubs.
  (`test/standards_test.rb` S12). Stale claims are bugs.

## Deploy

This repository is the product and deploys nothing. CI publishes the app
image and the computer image from every main commit whose `bin/ci` passed,
tagged with the commit (`.github/workflows/ci.yml`, `publish`). Installs keep
their configuration elsewhere and build `FROM` a pinned image
(`docs/deployments.md`). Each install's owner pins and deploys.

- The interface is the images, the settings in `.env.example` and the storage
  layout. Keep all three backwards compatible within reason, and say in the
  commit when one changes.

- Generic code only. No install's hosts, addresses, people, vault ids,
  credentials or deploy destinations here: an install-specific value is a
  setting (`.env.example`) or a line in the install's own destination file.
- `config/deploy.example.yml` and `.kamal/secrets.example` are the example
  destination, checked by the tests like a real one. Keep them working.
- A change that would force an install to edit a template file is a missing
  setting: add the setting instead.
- Never commit or print a secret.
- Changes at the sign-in provider (the OIDC client, its redirect URIs) land
  there first, before this app depends on them.

## Do not build

- Devise, Inertia, Vite, Puma, Thruster, the `dotenv` gem, `app/services/`.
- Anything the north star above rules out; add it here when you decide it.

## Agent sidecar (optional Pi Durable)

This app was generated with `PI_DURABLE=1`. `docs/agent.md` is the runbook: processes, tokens, retained state, backup and restore, and the limits of what it isolates.
