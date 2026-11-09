# Installs

This repository is the **durable-assistants** product: the code, its tests and
CI, and the images it publishes. It deploys nothing itself and holds no
install's hosts, addresses, people, vault ids or credentials.

An **install** runs the published image with its own configuration, the way a
ONCE product is installed: it does not copy or merge this repository's code.
The examples below use **acme**, an install that is one folder in its
owner's own repository.

## The interface

Three things, and nothing else, are shared between this repository and an
install:

| What | Where |
|---|---|
| The images | `<owner>/durable-assistants:<commit>` (the app: web, job and the agent sidecar) and `<owner>/durable-assistants-agent:<commit>` (an agent's computer), published by CI from each green commit. |
| The settings | `.env.example`, each one documented. |
| The storage layout | One volume at `/rails/storage`: the SQLite databases, uploads, and `agent/` (the sidecar's store, socket and model-account file). |
| The office | `config/deploy.example.yml`'s accessories, each pinned (`docs/office.md`). |

**Publishing.** `.github/workflows/ci.yml` runs `bin/ci`; on main, its
`publish` job then builds both images from that commit and pushes them tagged
with its full sha. `publish` needs `ci`, so a commit whose `bin/ci` failed is
never published, and a commit is the only tag: there is no `latest`.

An install pins one commit for both: its Dockerfile's `FROM` and its
`SPRITES_IMAGE`. Updating is changing that commit, making the same change as
`git diff <old> <new> -- config/deploy.example.yml` to its destination file
(the office's pins, `docs/office.md`), and deploying.

## An install's workspace

```
acme/assistants/              (any folder in the install's repository)
  Dockerfile                  FROM the published image, plus two COPY lines
  config/credentials.yml.enc  its own; the master key lives in its vault
  config/agents/<name>/       optional: its own starter agent; agent.yml may say
                              `computer: sprites` to give each agent a computer;
                              instructions.md writes {{name}} where each new
                              agent's own name goes, never the starter's name
  config/deploy.yml           from this repository's config/deploy.yml
  config/deploy.<dest>.yml    from config/deploy.example.yml, one per destination,
                              the office included
  .kamal/secrets.<dest>       from .kamal/secrets.example
  .kamal/hooks/               from .kamal/hooks/ (the destination and express gate)
  bin/kamal                   from bin/kamal; the pre-deploy hook runs it
  bin/passbolt-fetch          from bin/passbolt-fetch; the secrets file runs it
  Gemfile                     gem "kamal", and nothing else
  ops/backup/                 from ops/backup/ (README.md there)
  its own notes
```

The Dockerfile:

```dockerfile
FROM ghcr.io/ajaynomics/lanyard:<commit>
COPY config/credentials.yml.enc config/credentials.yml.enc
COPY config/agents/robin config/agents/robin
```

Kamal builds it, which is what gives the image the install's `service` label;
Kamal refuses to run an image without one. Kamal builds from a clone of the
repository at the workspace's folder, so the workspace can live anywhere in
it. The builder must be able to pull the published image (`docker login` to
the registry once on that host).

Nothing else from an install reaches the image. Built into the published
image, and so the same for every install: the code, gems, the sidecar's
packages, the compiled assets (no setting is read at build time; `APP__NAME`
and the rest are read when the app starts), the starter agent
`config/agents/assistant`, and the tools the app runs (`node`, `chromium`,
`sqlite3`, the Passbolt client). An install that needs any other file in the
image has found a missing setting: ask for it here.

`config/deploy.example.yml`, `.kamal/secrets.example` and `.kamal/hooks/`
stay in this repository as the example an install starts from; the tests check
them like a real destination, so they keep working.

## What an install sets

Every setting is listed in `.env.example`. These are the ones an install
normally sets in its destination files:

| Setting | What |
|---|---|
| `APP__NAME` | The deployment's name on its screens and installed app, and the name connected services see. |
| `APP__URL` | Its address. |
| `APP__REDIRECTS` | Optional: other hostnames, comma-separated, that answer every request with a 302 to `APP__URL`, path and query kept, before sign-in. List each in the proxy's `hosts` beside `APP__URL`'s. |
| `OIDC__ISSUER`, `OIDC__CALLBACK_URI`, `ACCESS__EMAILS`, `ACCESS__ADMINS` | Its sign-in provider, admitted people and admins (README.md, Signing in). The client id and secret come from its vault, through `.kamal/secrets.<destination>`. |
| `APP__STARTER_AGENT` | The folder under `config/agents` a new person's first agent is made from. |
| `APP__APPROVALS` | `ask` (the default) or `allow`: every call that would ask the person's approval runs at once, for every agent, even those never "Always", except what asks every time (an iMessage). Questions and sign-ins still wait. |
| `APP__APPROVE_EVERYTHING` | `false` (the default) or `true`: no call waits for an approval card, not even an iMessage, except sending mail, deleting a draft or an event, and an event that reaches other people, through a Gmail or Calendar connector (docs/connectors.md). Each is still recorded in its thread; questions and sign-ins still wait. |
| `PI_DURABLE__COMPUTERS`, `PI_DURABLE__SPRITE_PREFIX`, `SPRITES_*` | Its agents' computers. The prefix names its Sprites on the platform. |
| The office's keys | `CAMPFIRE__ADMIN_*`, `WIKI__API_KEY`, `CRM__API_KEY`, `PASSBOLT__PRIVATE_KEY`, `PASSBOLT__PASSPHRASE`, from its vault. The office's addresses need no setting (`docs/office.md`). |
| `CONCOURSE__ORIGIN`, `CONCOURSE__TOKEN_URL` | Optional: the agents' mail network and its token address. Without both, no agent is offered Concourse. |
| `MAIL__DOMAIN`, `MAIL__SMTP_*`, `MAIL__IMAP_*` | Optional: the agents' email (`docs/email.md`). |
| `CALDAV__URL` | Optional: calendars and task lists, each agent as its own account (`docs/calendar.md`). |
| `VOIPMS__USERNAME`, `VOIPMS__PASSWORD` | Optional: texts from an agent's own number (`docs/phone.md`). |
| `BLUEBUBBLES__URL`, `BLUEBUBBLES__PASSWORD` | Optional: iMessage from the owner's own phone, through BlueBubbles on their Mac (`docs/imessage.md`). |
| `WEB_PUSH__PUBLIC_KEY`, `WEB_PUSH__PRIVATE_KEY`, `WEB_PUSH__SUBJECT` | Optional: notifications on people's devices (Notifications, below). The private key goes in credentials or the vault, never a destination file. |
| `AGENT_APPLICATION` | The sidecar's name for the install, which every stored model-account sign-in is sealed to. Changing it means signing in again. |
| `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` | Its name in telemetry, and `deployment.destination=<destination>`. |
| `x-express: <VARIABLE>` | Not a setting but a line in a destination file: the hooks refuse that destination unless the deploy runs with `<VARIABLE>=1`. Use it for production, for example `x-express: ACME_PRODUCTION_EXPRESS`. |

A destination file also sets `service:`, `image:` and `volumes:`. Kamal names
containers and the volume after the service, so acme sets `service: acme`,
`image: acme` and `acme_storage:/rails/storage`, along with the web role's
`network-alias` and the agent's `AGENT_RAILS_URL` (`acme-web`), and the same
prefix on the office's volumes and the names its accessories reach each other
by (`acme-crm-redis`).

## Notifications

Web Push needs one VAPID key pair per install: the push services check every
notice against it. Make the pair once, in a checkout of this repository:

```sh
bin/rails runner 'key = WebPush.generate_key; puts key.public_key, key.private_key'
```

Set the first line as `WEB_PUSH__PUBLIC_KEY` and keep the second,
`WEB_PUSH__PRIVATE_KEY`, in credentials or the vault. `WEB_PUSH__SUBJECT` is
how a push service reaches whoever runs the install, a `mailto:` or `https:`
address; unset, it is `mailto:` and `APP__MAILER_FROM`, if that is set. One key
without the other, or keys with no subject, fail a production boot. Keep the
pair: a new one stops every device's notifications until each person turns
them on again. Without keys, push is off and Settings does not offer it; the
badge and the Share sheet work either way. What a notice holds is in
`docs/design.md`, "Notifications, badge and sharing".

## Creating an install

The machine that deploys needs Ruby, Docker, the Passbolt CLI (signed in) and
`jq`, which `bin/passbolt-fetch` uses to read the vault's answer.

```shell
mkdir -p acme/assistants && cd acme/assistants
# copy the files above from a checkout of this repository at the commit to pin
cp <this repository>/config/deploy.example.yml config/deploy.production.yml
cp <this repository>/.kamal/secrets.example .kamal/secrets.production
mkdir -p bin && cp <this repository>/bin/kamal <this repository>/bin/passbolt-fetch bin/
# a new credentials file: in a checkout of this repository with no
# config/credentials.yml.enc, run bin/rails credentials:edit, then move
# config/credentials.yml.enc and config/master.key here
# put config/master.key in the vault and delete it; fill in the destination
# and secrets files, then:
bin/kamal deploy -d production
```

A change any install could use is made here, published, and then pinned.

## The agent image

`publish` builds the computer's image (`Dockerfile.agent`) from the same commit
as the app. Pin the same commit in `SPRITES_IMAGE`, so the sidecar and the
computers it drives always come from one commit.

## Renaming a running deployment

Kamal finds a running deployment by its names, so a rename is a move, not an
edit. Before the first deploy under new names:

- **Data.** A new `service` means new containers and a new volume. Stop the old
  containers, copy the old volume into the new one (or restore the latest
  backup into it, `ops/backup/README.md`), then deploy. The old names are left
  for a rollback until the new ones are proven.
- **Sign-ins.** Keep the old `config/credentials.yml.enc` and master key: its
  `secret_key_base` seals connector sign-ins and headers. People sign in to the
  app again once if the session cookie's name changed.
- **Model accounts.** A new `AGENT_APPLICATION` cannot open grants sealed under
  the old one: sign in again at /subscriptions.
- **Computers.** A new `PI_DURABLE__SPRITE_PREFIX` names new Sprites only; an
  existing computer keeps its stored name. Agent images from before
  8 November 2026 greet the relay under an older name, not `AGENT-RELAY`, so
  after pinning a newer `SPRITES_IMAGE` those computers must be made again.
- **Backups.** Point the backup units at the new `BACKUP_SERVICE`.
- **Telemetry.** A new `OTEL_SERVICE_NAME` starts a new series.
