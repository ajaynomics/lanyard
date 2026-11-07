# Saved sign-ins

The office's vault (`docs/office.md`) is the install's own Passbolt, run as a
Kamal accessory beside the app. People keep sign-ins there and share a folder
with one Passbolt user that every agent of the install uses. An agent can then
sign in to a site on its computer without anyone typing the password for it.

An agent may have a Passbolt user of its own instead (below, "An agent's own
user"), so what it saves and reads is its own and Passbolt shows its name.
Until an agent has a key and passphrase, its own or the shared user's, it has
no saved-sign-in tools at all.

## What the agents can do

Three tools, given to every agent whose computer is a Sprite (it needs the screen's
browser) while the install has a password manager:

| Tool | What it does |
|---|---|
| `list_saved_sign_ins` | Names and sites of what is shared with the agents. Never a password. |
| `sign_in_with_saved_password` | Fills one sign-in into the page the agent last opened with `visit_website`. The person approves each use. The agent then presses the page's own button. |
| `ask_for_sign_in` | Asks the person for a sign-in the agents lack. A form on the person's own page of the thread takes the username and password and saves them to the vault; the agent learns only that it was saved. |

**Asking for one.** The form is the call's card, behind the person's sign-in,
like an approval: nobody else can answer it, and it lasts as long as any wait.
The password goes from that one request to the vault
(`Conversations::Invocations::SignInsController`), never to the model, the
database, the page or the log. It is saved as the agents' user, so it is
theirs: people do not see it in their own Passbolt unless the agents' user
shares it, and a name already saved is refused rather than duplicated. The
command line takes the new password only as an argument, so for its few
seconds it is in the web container's process list.

How a sign-in reaches the page:

1. The model asks for a sign-in by name. The person approves or denies the
   exact call, as for any sensitive tool.
2. Rails looks the name up in Passbolt and records only the name and site
   (`Tool::SignInWithSavedPassword`).
3. The sidecar, seeing that the call fills the browser, asks Rails for the
   password once (`POST /agent/sign_ins`, within five minutes of the approval)
   and passes it to `agent/guest/fill.mjs` on the Sprite in that command's
   environment.
4. `fill.mjs` fills the visible username and password fields, only if the page
   is on the sign-in's own site (or a name under it) over https. It never
   submits.
5. The model reads which fields were filled on which page.

The password is never in the model's input, the tool's result, the
conversation, Rails' database or a log line (`test/integration/saved_sign_ins_test.rb`,
`agent/test/sign-in.test.mjs`).

**The limit.** The password is typed into a browser on the agent's own
computer, where the agent also has a shell. An agent set on it, by its own
mistake or a page's instructions, could read a filled field back. The approval
for each use is what stands between that and a password: share with the agents
only sign-ins it is acceptable for them to hold, and approve a use only when
the agent is on the page you expect.

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

### An agent's own user

Register a user for the agent the same way as step 3 (`-r user`, an address
such as `jordan@example.com`), keep its recovery kit and passphrase in the
install's vault, and give them to the agent in a console on the web role:

```ruby
agent.update!(passbolt_private_key: File.read("recovery-kit.txt"), passbolt_passphrase: "...")
```

Both are encrypted in the database, and the agent then reads and saves as its
own user, with the shared one untouched for agents without one. A key without
its passphrase counts as none. Share sign-ins with agents through Passbolt
groups (one per team of agents, say); what an agent saves is its own until
someone shares it. Clear both columns to put the agent back on the shared
user. With every agent on its own user, the shared settings can go.

The app reaches Passbolt with its command-line client (go-passbolt-cli, pinned
in `Dockerfile`), as the agents' user, with its key and passphrase passed in
the command's environment. `lib/durable_assistants/passbolt.rb` is the only
code that speaks to it. It runs in the web and job containers, on the same
host as the accessory, and goes to it by its container name, so the public
address and whatever guards it never come into it. The vault's client, key
and address never go onto an agent's computer, which is a remote machine off
the host's network: only the one password does, typed into its browser
(`test/integration/saved_sign_ins_test.rb` holds both).

## Not here

- Saving or changing a sign-in from the app: people use Passbolt itself.
- Signing in without a screen (a local computer, or a helper agent).
- A page for an agent's own Passbolt user: it is set in a console.
- The vault the install's operators use for deploy secrets, even if it is
  also Passbolt. This is a separate one, for the agents alone.
