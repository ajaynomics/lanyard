# Saved sign-ins

The office's vault (`docs/office.md`) is the install's own Passbolt, run as a
Kamal accessory beside the app. People keep sign-ins there and share a folder
with one Passbolt user that every agent of the install uses. An agent can then
sign in to a site on its computer without anyone typing the password for it.

A shared workspace may have a Passbolt user of its own (below, "A
workspace's own user"), so its agents see only what is shared with it, never
the install's folders. An agent may have a user of its own too (below, "An
agent's own user"), so what it saves and reads is its own and Passbolt shows
its name. The first of the agent's own, its workspace's and the install's
shared user is the one it acts as, for every use of the vault: sign-ins, mail
and calendar passwords, a Telegram token, API keys and links for someone
outside (`DurableAssistants::Passbolt.connection_for`). Until an agent has a key and
passphrase from one of them, it has no saved-sign-in tools at all.

## What the agents can do

Four tools, given to every agent whose computer is a Sprite (it needs the screen's
browser) while the install has a password manager:

| Tool | What it does |
|---|---|
| `list_saved_sign_ins` | Names and sites of what is shared with the agents. Never a password. |
| `sign_in_with_saved_password` | Fills one sign-in into the page the agent last opened with `visit_website`, its tab in front of the screen's browser. The person approves each use. The agent then presses the page's own button. Its `security_question` step answers the question that page asks from the answers saved with the sign-in, and sends it. |
| `ask_for_sign_in` | Asks the person for a sign-in the agents lack. A form on the person's own page of the thread takes the username and password and saves them to the vault; the agent learns only that it was saved. |
| `ask_outside_for_sign_in` | Gets a one-time link for someone outside the install to type a sign-in straight into one empty entry (below, "From someone outside"). The person approves every one; the agent sends it on and learns only whether it was filled. |

The three sign-in tools that ask the person still show their cards under
**Approve everything** and **Allow everything**. They never offer **Always**.

**Security questions.** Save each one on the sign-in as a Passbolt custom
field: the question as the field's name, exactly as the site words it, and
the answer as its value. The step fills an answer only when the page's
question is the saved one, apart from case and spacing; otherwise it fills
nothing and tells the agent the page's question, so it can ask the person.
Just before typing it rechecks the question, the unambiguous answer field
and its form. A changed page is left untouched; ask to use the sign-in again.
It then sends the page's form as the site set it, leaving every box ticked
or not as it was. The answer is typed hidden and is never shown to the
model, the chat or a log. A site's address may be saved
as a bare domain (`example.com`): it means that site over https.

**Asking for one.** The form is the call's card, behind the person's sign-in,
like an approval: nobody else can answer it, and it lasts as long as any wait.
The password goes from that one request to the vault
(`Conversations::Invocations::SignInsController`), never to the model, the
database, the page or the log. It is saved as the agents' user, so it is
theirs: people do not see it in their own Passbolt unless the agents' user
shares it, and a name already saved is refused rather than duplicated. The
password goes to Passbolt on a command's standard input, never in its
arguments, which every account on the host can read (below).

How a sign-in reaches the page:

1. The model asks for a sign-in by name. The person approves or denies the
   exact call, as for any sensitive tool.
2. Rails looks the name up in Passbolt and records only the name and site
   (`Tool::SignInWithSavedPassword`).
3. The sidecar, seeing that the call fills the browser, asks Rails for the
   password once (`POST /agent/sign_ins`, within five minutes of the approval)
   and passes it to `agent/guest/fill.mjs` on the Sprite in that command's
   environment. It runs as the browser's own user, through the relay, never
   through a process of the agent's (`docs/agent.md`, #60). Passbolt can take
   15 to 25 seconds to answer, so the sidecar waits a minute for this one
   callback. Rails fetches the password before it spends the approval: a
   Passbolt error, or an answer after 45 seconds that the sidecar may have
   stopped waiting for, leaves the approval to collect again.
4. `fill.mjs` fills the tab `visit_website` last opened (`~/.visit-tab`),
   which it brought to the front of the screen's window, as `answer.mjs` and
   `pay.mjs` do; never a tab of the person's, even one in front. A sign-in a link opened in a new tab is
   filled once the agent opens that page with `visit_website`.
   It fills the page, or a frame in it, whose own address is on the
   sign-in's site (or a name under it) over https: Apple's sign-in, a frame
   from `idmsa.apple.com` inside `www.icloud.com`, fills from an entry for
   `https://idmsa.apple.com`; a page on the site never fills another site's
   frame. A frame with a password field comes first, the page before its
   frames. When nothing on the site is there, it fills nothing and says which
   tab (its title) and site it saw. It never submits.

   It fills only fields a person can see and reach: not hidden, under
   `aria-hidden`, smaller than 2 pixels, clipped away or off the page. The
   username is the field before the password, preferring one marked for it.
   Without a password field (a username-first step, as Google's and Apple's)
   it fills only a field marked for the username (`autocomplete` username or
   email, `type=email`, or a name, id or label saying user, login or email),
   and otherwise refuses, saying there is no password field.

   **An account box.** Some sites ask for an account number besides the
   username, as a bank's Account Number, User ID and Password. Save it in the
   entry's description as a line `Account: 12345` (the key in any case, the
   value trimmed; the first such line counts). Rails reads only that line,
   from the description Passbolt keeps encrypted with the password, and it
   goes to `fill.mjs` with the password, the same way. The account box is a
   field a person can see and reach, before the password on its form, never
   the username's, whose name, id, label, placeholder or `autocomplete` says
   account, firm, company or organisation, or a customer, client or member
   number; it is filled first. A page with one, when the entry has no account,
   is not filled at all: the agent is told to ask the person for it. An entry
   with an account on a page with no such box fills the username and password
   as before, and the agent is told the account was not needed. A field
   saying account is still the username when it is the only text box before
   the password.
   `fill.mjs` runs from the computer's image, so a computer made before
   this fills only the username and password; the agent is told the account
   box may still be empty, and to type it or have the computer made again.

   **Named password boxes.** A page that sets a password asks for it twice,
   a new password and a box to confirm it, and saves nothing until both
   match (setting an API password from a saved entry, say). The agent names
   each box by CSS selector in `password_fields` (up to four, `sign_in` step
   only). Then the password goes into those boxes alone: no username, no
   account. Each must be a password box a person can see and reach, in the
   page or a frame on the sign-in's site; one that is a text box, hidden or
   missing fills none of them, since a text box would show the password on
   the screen the model sees. The selectors are kept with the call, the
   password is not. The approval is the same as any other fill. The password
   goes to `fill.mjs` under its own key, so a computer made before this finds
   none, fills nothing, and the agent is told to have the computer made again.
5. The model reads which fields were filled on which page.

**A sandboxed agent's own browser.** The install maps a Rails agent ID to
one exact host browser with `pi_durable.sandbox_browsers` (for example,
`"17=avery"`): a headless Chromium the host runs as the agent's sandbox
user. Neither an SSH setting nor a tool argument can supply the browser name.
This is the fallback for an agent with no desktop. An agent with a desktop
(its Sprite's screen, or the one an SSH computer keeps) is filled
there, in the tab `visit_website` opened, even when it is mapped here too:
one browser per agent, the one the person and the agent are looking at
(`Agent#browser_without_desktop`, `Agent#sandbox_drive_browser`,
`agent/sign-in.mjs`).

1. `visit_website` opens an HTTPS page through the host's act helper,
   `/run/agent-browser/<name>/act.sock`, from the agent's SSH computer
   (`agent/sandbox-browser.mjs`). The helper offers a fixed set of actions,
   never a DevTools call or a script. The model reads the page's address,
   without its query or fragment, and its title.
2. `sign_in_with_saved_password` still needs the usual approval. The sidecar
   fills the tab the helper uses through `/run/agent-browser/<name>/fill.sock`,
   a fill-only adapter (`agent/fill-socket.mjs`) that refuses any call a fill
   does not make. The focus stays on the password box. No security questions
   yet. The host holds an agent's fills by making `fill.sock` unreadable to
   the sidecar. A refused socket tells the agent that sign-ins are paused for
   this browser and not to try again, rather than that its browser is down.
3. `visit_website` with `action: "submit"` and no `url` sends the form that
   has the focus.

The helper reads no form value back, and refuses to read the page or type
while a password box has the focus. The helper lives on the install's host,
not in this repository, and so does the test that proves both: the host's
`act-page-text-test.sh`, beside the helper, runs the real helper against a
real Chromium with a filled box and a made-up password, and fails if the page
text holds the value or a read is allowed while the box has the focus. It is
one of the host's checks after a deploy. `agent/test/sandbox-browser.test.mjs`
covers only this repository's side, the `visit_website` tool, against a fake
helper.
The browser's raw DevTools socket gives a filled box back to anyone who can
open it, so the agent's account must not reach it.

The password, and the account, are never in the model's input, the tool's
result, the conversation, Rails' database or a log line (`test/integration/saved_sign_ins_test.rb`,
`agent/test/sign-in.test.mjs`).

**The limit.** The password is typed into a browser on the agent's own
computer, where the agent also has a shell. An agent set on it, by its own
mistake or a page's instructions, could read a filled field back. The approval
for each use is what stands between that and a password: share with the agents
only sign-ins it is acceptable for them to hold, and approve a use only when
the agent is on the page you expect.

## From someone outside

Sometimes the sign-in belongs to someone outside the install: a client's
bank login, held by their lawyer, say. `ask_outside_for_sign_in` gets them a
link to type it straight into the vault, so it never passes through an
agent, an email or a chat (`SignInLink`, `Tool::AskOutsideForSignIn`).

1. Someone makes the entry in Passbolt first, with its name and site and no
   password, and shares it with the agents' user. A link fills only an entry
   that is empty: it never overwrites a saved password. To change one, empty
   it in Passbolt first, then ask again.
2. The agent names the entry. The person approves the exact call **every
   time**, never "Always", even where the install approves everything
   (`APP__APPROVE_EVERYTHING`): the link lets a stranger write into the vault.
3. Rails checks the entry is shared with that agent and still empty, makes
   the link, and gives the agent only the link and when it expires. The
   agent sends it on. The link is in the call's result, as any result is,
   so the agent can send it; the link's own table keeps only its token's
   digest.
4. The page shows a plain form: username, password and an optional account
   number. Opening it uses nothing up, since mail scanners fetch links before
   people do. The page has no script, keeps no copy (`no-store`) and sends no
   referrer.
5. The first submit uses the link up, then writes, inside that request:
   `passbolt-save fill` reads the sign-in on standard input, refuses an entry
   that has gained a password meanwhile, puts the account in the entry's
   encrypted description as a line `Account: ...` (the one the fill reads,
   above), and encrypts the secret again for everyone the entry is shared
   with. A second submit, from any browser, is refused, as is a used,
   expired or revoked link, each with a plain page. A write that fails says
   so; that link is used up, and the person sends a new one.
6. The agent hears, in its thread, one of: filled, not filled (the write
   failed, or the person revoked it), or expired unused. Never what was
   typed.

The link lasts 30 minutes and fills exactly one entry. Its card in the thread
says where it stands, and Revoke ends it while it is open. What the visitor
types never reaches the model, the database, a job's arguments, a log line or
a command's arguments (`test/integration/sign_in_links_test.rb`). An entry
whose type keeps its description unencrypted (Passbolt's old
password-only kind) takes no account: the write is refused rather than put
it in the clear.

Anyone holding the link can use it in that half hour, as with any emailed
link: send it only to the person meant to fill it, and revoke it if it went
astray.

## Calling an API with a saved key

`call_api_with_saved_key` is for a service with an API rather than a page to
sign in on. It is picked one by one in an agent's settings, never given: a
key acts in someone's account. It needs the password manager, not a computer.

- Save the key as a vault entry's **password**, and the API's host as its
  **address**: `api.cal.com` or `https://api.cal.com`. That host, over https,
  is the only one the entry can reach. An `http://` address reaches nothing.
- The agent names the entry and gives a method, a path on that host, and
  optionally query parameters, a JSON body and extra headers (an API version,
  say). It cannot set `Authorization`, `Host`, `Cookie` or
  `Proxy-Authorization`, or name another host.
- The first call with each key shows a card, even under **Approve everything**
  or **Allow everything**. The person may answer **Always** for that key; a
  call with another key asks again.
- Rails reads the entry as the calling agent, so only an entry shared with
  that agent works, and sends exactly one request with the key as
  `Authorization: Bearer <key>`. Redirects are not followed.
- The model gets the status and the first 40 KB of the body. The key never
  reaches the agent's computer, the model, the ledger or a log. Should an API
  echo it, the answer shows `[the saved key]` instead
  (`test/integration/saved_key_api_calls_test.rb`).
- The request is `DurableAssistants::KeyedRequest`.

A saved sign-in can also open one calendar in another CalDAV account, such as
a shared iCloud calendar; [calendar](calendar.md#a-linked-calendar-from-another-account)
says how, and how the rest of that account stays out of reach.

A saved sign-in can also be the agent's own mail account, which it sends
from and reads; [email](email.md#its-own-mail-account) says how. Its address must
name the SMTP server, or nothing is sent or read, and the incoming server
must be that server or one beside it in the same domain.

A saved sign-in can also be the account on the agent's own calendar server,
in place of the install's; [calendar](calendar.md#its-own-calendar-server)
says how. Its address must name that server's host.

A sign-in one of these uses (its mail account, its calendar server or its
linked calendar) is the app's to use for the agent, never the agent's own:
`list_saved_sign_ins` leaves it out, and `sign_in_with_saved_password` and
`call_api_with_saved_key` refuse it, matched by name whatever its case, as
the sidecar's collection of the password does for a fill approved before.
Filled into the same host's webmail, a mailbox's password would send mail
around the forced Bcc and every approval.

## Creating a Turnstile preview widget

Use **Create Turnstile preview**, not the raw saved-key tool. It is off by
default, available only to a selected agent in the configured workspace,
and always asks its designated owner for the exact account, project,
preview environment and hostname.

The install needs a dedicated, approved release vault principal and trust
anchor, not its ordinary Passbolt user. Configure two existing read-only
`password-and-description` records addressed to `https://api.cloudflare.com`:
a user API token for **Turnstile Sites Write**, and a separate **Pages Write**
token, both scoped to the preview account. Cloudflare does not list Turnstile
as compatible with account-owned tokens. Never use a Global API Key.
Place the release vault key and passphrase in encrypted Rails credentials
under `turnstile_preview`, never in environment variables. The pinned
in-process vault library checks the authenticated user and reads only the
configured records. Nothing is written back to Passbolt.

The tool checks the project identity and refuses an existing preview binding.
It creates one managed widget and sends its secret to the encrypted
`deployment_configs.preview.env_vars.TURNSTILE_SECRET` Pages binding.
Only the Pages Function should read it for server-side Siteverify. The public
site key can appear in static files; the secret cannot. A preview binding
applies to the project's preview environment, not a single preview branch.
Use a dedicated preview project. No file upload, deployment, production
binding, domain change or mail Worker update is part of this tool.

Success shows only the public site key and status. A confirmed bind refusal
attempts one deletion of the just-created widget. An uncertain outcome leaves
the widget alone because the binding might have succeeded. Check Pages and
Turnstile before allowing any new attempt. Do not run concurrent writers on
the same preview configuration: the preflight does not lock Pages settings.

## Adding it to an install

1. **The accessories.** `passbolt-db` and `passbolt` are in
   `config/deploy.example.yml`'s office, with the install's own host and
   address in its destination file. Passbolt stores its data in MariaDB, the database its
   image is set up for. Add `PASSBOLT_DB_PASSWORD` to `.kamal/secrets.<name>`.
   Route the address to the host as for the app; it is for people, and may
   sit behind the install's own sign-in page (Cloudflare Access, say). The
   app never uses it (below).

   ```shell
   bin/kamal accessory boot passbolt-db -d <name>
   bin/kamal accessory boot passbolt -d <name>
   ```

   Its keys and database live in named Docker volumes (`<service>_passbolt_gpg`,
   `_jwt` and `_mysql`), which start with the image's own
   ownership, so Passbolt can write them. The gpg volume holds the server's
   key: never delete it, or every person must set up again. (An install that
   used Kamal `directories:` instead must `chown 33:33` and `chmod 750` the
   gpg and jwt folders on the host before the first boot, and must never run
   `kamal accessory remove`, which deletes them.)

   If the first boot fails its health check, kamal-proxy never gets the
   route, and `kamal accessory reboot` then fails with "service not found".
   Remove the stopped container with `docker rm` on the host and run `boot`
   again.

2. **The first people, without mail.** Passbolt invites by email; the
   accessory sends none. Its own command line makes the invitation and prints
   the link instead:

   ```shell
   bin/kamal accessory exec passbolt -d <name> --reuse \
     "su -m -c '/usr/share/php/passbolt/bin/cake passbolt register_user -u you@example.com -f First -l Last -r admin' -s /bin/sh www-data"
   ```

   Open the link in a browser with Passbolt's extension installed and finish
   the setup there. The extension is how people add, change and share
   sign-ins: nothing in the app does it.

3. **The agents' user.** Register one more user the same way, with `-r user`
   and an address the install controls (for example `agents@example.com`).
   Open its link in a separate browser profile with the extension, choose a
   passphrase, and download the recovery kit: that file is the user's
   private key. Put the key and the passphrase in the install's vault and in
   `.kamal/secrets.<name>` as `PASSBOLT__PRIVATE_KEY` and
   `PASSBOLT__PASSPHRASE`. Then close that browser profile. Nobody signs in
   as the agents again. Kamal hands the key to the container on one line,
   its newlines escaped as `\n`; the app turns them back into newlines.
   Without a browser, go-passbolt's `helper.SetupAccount` can finish the
   user's setup from its link instead.

4. **The settings.** On web and job, add the two secrets, then deploy.
   `PASSBOLT__URL` can stay unset: the app then reaches the accessory's
   container inside the host, `http://<service>-passbolt`, over Kamal's
   Docker network. Set it only for a Passbolt somewhere else. Pin a `SPRITES_IMAGE` built
   from a commit that has `agent/guest/fill.mjs`.

5. **Sharing.** In Passbolt, share a folder with the agents' user. The agents
   see what is in it and nothing else; take a sign-in out of the folder to
   take it back. To check, in a console on the web role:

   ```ruby
   DurableAssistants::Passbolt.sign_ins(agent).map(&:name)
   ```

### A workspace's own user

Register a user for the workspace the same way as step 3 (an address such as
`household@example.com`) and keep its recovery kit and passphrase in the
install's vault. The workspace's owner then pastes the private key and its
passphrase on the workspace's page, under Saved sign-ins (`Workspaces::VaultUsersController`).
Both are encrypted in the database and never shown again; its members see only
that it has its own. Its agents then read and save as that user, unless one
has its own, and nothing they do reaches the install's shared user. Share the
workspace's sign-ins with that user in Passbolt. Remove it on the same page to
put the workspace back on the install's user. Without one, a workspace is on
the install's user exactly as before. A personal workspace has no page, so
this is for shared ones.

A workspace may have a Passbolt server of its own too. Its owner enters the
server's https address on the same page, with that server's user. Its agents
then read and save only there, each as its own user if it has one or else as
the workspace's, and never on the install's server. If the server is set but
no whole user is, every use refuses (`Passbolt::MissingVaultUser`) rather than
read the install's. Without one, the workspace's user is one on the install's
server.

The Go code that reads and saves (`passbolt-save/vaultdial`) checks each
connection's address as it is made, a redirect's included, and refuses this
machine and its private network as `McpServer::Address` does, so a server
whose name rebinds inside after Rails' check is refused too. Only the hosts
in `CONNECTORS__INTERNAL_HOSTS` and the install's own server are let through.

### An agent's own user

Register a user for the agent the same way as step 3 (`-r user`, an address
such as `jordan@example.com`), keep its recovery kit and passphrase in the
install's vault, and give them to the agent in a console on the web role:

```ruby
agent.update!(passbolt_private_key: File.read("recovery-kit.txt"), passbolt_passphrase: "...")
```

Both are encrypted in the database, and the agent then reads and saves as its
own user, before its workspace's or the shared one, which stay untouched for agents without one. A key without
its passphrase counts as none. Share sign-ins with agents through Passbolt
groups (one per team of agents, say); what an agent saves is its own until
someone shares it. Clear both columns to put the agent back on the shared
user. With every agent on its own user, the shared settings can go.

The web and job processes read a configured HTTPS Passbolt directly. The
Ruby client uses the same in-process Go/OpenPGP library as the release vault,
with a separate read entry point for saved sign-ins. It checks the server's
certificate and never follows redirects or falls back to a command. A list
or name lookup returns only names, addresses and IDs; only an individual read
retrieves and decrypts its secret. No key, passphrase or decrypted vault
response goes through a child process for those HTTPS reads.

The existing internal HTTP accessory still uses `go-passbolt-cli` for reads.
Do not expose that HTTP route outside the install's private network. These
commands run in the web and job containers using the selected Passbolt user,
with the key and passphrase in the command's environment. They ask for
`--json` only on `list` and `get`, where the flag is supported
(`test/lib/passbolt_test.rb`).

The vault's client, key and address never go onto an agent's computer.
Only the sign-in it needs does, to fill the browser on the saved site
(`test/integration/saved_sign_ins_test.rb`).

**No secret in a command's arguments.** Every account on the host can read
any process's arguments (`/proc/<pid>/cmdline`); only its own user and root
can read its environment. go-passbolt-cli (0.5.3, the latest) takes a new
entry's password only as `--password` or `--secret-field`, read straight from
the flags. So a save goes through `passbolt-save` instead
(`passbolt-save/main.go`, a few lines on the go-passbolt library the CLI is
built on, compiled in its own stage of `Dockerfile` with its modules pinned
by `go.sum`): it reads `{"name", "uri", "username", "password"}` on standard
input and the address, key and passphrase from the same environment, and
prints the new entry's id. Its `fill` mode, for a link from someone outside,
reads `{"id", "username", "password", "account"}` the same way. The passphrase
and key stay in the environment as before. The app refuses to run `passbolt` with a secret flag
(`--password`, `-p`, `--secret-field`, `--userPassword`, `--userPrivateKey`,
`--totpToken`, `--mfaTotpToken`), so nothing slips back onto the command line.
On the existing HTTP command path, a password read from Passbolt returns on
the command's output, which the app does not log.

`test/lib/passbolt_argv_test.rb` checks this against a real, throwaway
Passbolt: it saves a marker with the real commands while it reads every
process's arguments and every environment it can, and fails if the marker is
there. It needs Docker for the server, so `bin/ci` skips it; its comment says
how to run it.

The isolated HTTPS protocol test generates throwaway OpenPGP keys and uses
a TLS server bound to loopback. Run it from `passbolt-save/` after installing
the app's Ruby gems and the pinned Go toolchain:

```sh
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
CGO_ENABLED=1 go build -mod=readonly -buildmode=c-shared -o "$scratch/reader.so" ./release-vault
PASSBOLT_READER_PROOF_LIBRARY="$scratch/reader.so" go test -count=1 -run TestProductReaderRubyHTTPS ./release-vault
```

This checks the read protocol without a real account or installation.
It does not replace a production-image or install-specific check.

## Not here

- Changing a saved sign-in from the app: people use Passbolt itself. A link
  from someone outside fills only an empty entry.
- Signing in without a screen (a local computer, or a helper agent).
- A page for an agent's own Passbolt user: it is set in a console.
- The vault the install's operators use for deploy secrets, even if it is
  also Passbolt. This is a separate one, for the agents alone.