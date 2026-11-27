# Computers

An agent's computer is where its file and shell tools run. Rails owns the
choice: the agent's `Computer` row names the kind, and the sidecar receives it
in the agent's definition (`Computer#descriptor`). There is no registry of
providers: a new kind is a new branch in `Computer`, a new module beside
`agent/computers.mjs`, and a row in the table below.

## What a kind must do

| Duty | Sprites | SSH | Local |
| --- | --- | --- | --- |
| Make and remove | Made on first use, one per conversation; deleted with the agent (`ComputerRemovalJob`) | Nothing to make: the folder exists. Deleting the agent leaves the folder as it is | A folder under storage |
| Wake and report its state | Wakes on use; `state` says when a disk comes back from cold storage | Always there, or unreachable | Always there |
| Run commands with live output; read and write files | pi-env's daemon, through the Sprite's relay | pi-env's daemon, over `ssh` | Node, here |
| Keep its disk while asleep | Yes | It is a real disk | Yes |
| git and ssh, to clone, check and push to a repository | Yes: the image carries them | Whatever the machine has | Whatever this machine has |
| Tools to check a document | Yes: the image carries them (below) | Whatever the machine has | Whatever this machine has |
| A desktop and its browser | Yes: the screen, the desktop tool, saved sign-ins, uploads and downloads (`~/browser-files`) | No screen; `visit_website` runs the machine's own Chromium headless, if it has one | No screen |
| Limit its internet | Not by this app: no egress list is set (see below) | None: it is the machine's network | None, or none at all with `AGENT_SHELL_NETWORK=isolated` |
| Command connectors | Through the relay | pi-env's daemon, over `ssh` | Here |
| Isolation | A microVM | None beyond the Unix user | None |

## Checking a document on a Sprite

An agent checks a document itself, on its computer, rather than trusting a
summary of it. The image (`Dockerfile.agent`) carries what that takes:

- **See every page.** `pdftoppm -png` (poppler) draws a PDF's pages, and the
  `read` tool shows each to the model as an image, shrunk to fit 2000x2000.
  Draw them as PNG: the read tool refuses pdftoppm's default PPM, saying so.
  `mutool draw` (MuPDF) draws one poppler refuses.
- **Read the words.** `pdftotext` for a text layer, `tesseract` (English) for
  a scan.
- **Repair or split a PDF.** `qpdf`, and `mutool clean`.
- **Open an archive of any size.** Info-ZIP's `unzip`, which opens ZIP64
  archives (over 4 GB or 65,535 files) that BusyBox's applet cannot, and `7z`
  for anything else.
- **Compare a draft with its source.** GNU `diff`, side by side if asked
  (`diff -y`); LibreOffice Writer renders a `.docx` to PDF first
  (`soffice --headless --convert-to pdf`).
- **Script the rest.** `python3`, `node`.

The image installs each, rather than an operator by hand, because a Sprite
made again from the image keeps only what the image installs.
`bin/check-computer-image` runs each, as the agent, in a built image.

## A Sprite's size

A Sprite is made with a number of CPUs, an amount of memory and a disk
(`Computer::Size`). Which: the agent's own size, else its workspace's, else
the install's default, part by part. The default is what every Sprite was
made with before sizes were settings: 2 CPUs, 2 GiB of memory and 8 GiB of
disk. Nobody goes past the install's maximum, `PI_DURABLE__COMPUTER_MAX_CPUS`,
`PI_DURABLE__COMPUTER_MAX_MEMORY_MIB` and `PI_DURABLE__COMPUTER_MAX_DISK_MIB`,
each the default when unset, so an install allows bigger Sprites only once it
says so; a size over it is refused, saying the most it allows, and one saved
before the install lowered it is made at the maximum.

- **Who sets it.** The owner of a shared workspace sets its default on its
  members page (Computer size); the owner of the agent's workspace sets the
  agent's own on its Computer page (Size). Everyone else in the workspace
  sees the size in use. A personal workspace has no members page: its owner
  sets each agent's.
- **When it applies.** A Sprite's size is fixed when it is made, and each
  conversation's is made on its first use, so a new size reaches only new
  conversations' computers. One already made keeps its size as it sleeps and
  wakes. To resize it, an operator remakes it with the agent's size
  (`docs/agent.md`, "Holding a computer"), which deletes its files. Nothing
  remakes one by itself.
- **How it travels.** Rails puts it in the computer it sends the sidecar
  (`size: {cpus, memoryMib, diskMib}`) and in the screen's address, which may
  make the Sprite, only when it is not the default; the bridge makes a
  Sprite at it (`wake --size`), else at the default. Only a Sprite has a size.

## A Sprite's internet

The app sets no network policy on a Sprite, so it reaches anywhere. Should
one ever be set, end it with a rule that denies everything: a list of allow
rules alone reportedly lets everything through. A test that a site off the
list is refused belongs with it.

## Over SSH

The agent works directly in a folder on a real machine, as one Unix user, as
a person does in a terminal: a home server, a laptop, any machine that answers SSH.
It is a deliberately sharp knife, so it is turned on in three places, all
needed:

1. The install lists it: `PI_DURABLE__COMPUTERS=sprites,ssh`.
2. The person chooses "A machine over SSH" for one agent, and gives the
   machine, the user and the folder. The agent's Computer page then says
   plainly where it works and that it is not isolated, and deleting the agent
   says its folder is left.
3. The machine lets the agent in: the person adds the agent's own key,
   shown on that page, to the user's `~/.ssh/authorized_keys`, and trusts the
   machine's host key there once, after comparing its fingerprint with one
   they got another way (on the machine, `ssh-keygen -lf
   /etc/ssh/ssh_host_ed25519_key.pub`). A host key that changes is refused,
   never trusted from the page: whoever runs the install removes the old one
   from that agent's `known_hosts` by hand.

Keys and trust are each agent's own (issue #59). Every agent has its own key
pair and its own list of trusted hosts, so a machine set up for one agent is
closed to every other agent, the same person's included: another agent would
offer a key the machine never saw, against hosts it never trusted. A machine's
user that another person's agent already works as is refused outright, with a
message saying so.

An agent on SSH can do whatever its user can: read that user's files, run
its programs, reach its network. A key of its own does not separate two
agents that work as one user: they share its files. Give each agent a user of its own, with
nothing in its home but the agent's folder, and keep it out of the `docker`
group: on a Docker host that group is root.

pi-env does the SSH (`agent/ssh-computers.mjs`): no prompts, no forwarding,
strict host keys against the person's own `known_hosts` under a fixed alias,
and its small daemon copied to the user's `~/.pi/mobile/tools/`, checked by its
hash before every start. Connections are kept per keyring, user and machine.
Rails names a computer's keyring (`computers.ssh_keyring`, `Computer#ssh_keyring`);
empty means the agent's own, `agent-<agent id>`. Each agent's key pair and
trusted hosts live in `storage/agent/ssh/agents/agent-<agent id>/`, beside the
sidecar's store, so they travel with its backup. A key pair is made on first
use; the private half never leaves the sidecar, and nobody pastes one anywhere.

Before keys were per agent, they were per person: `person-<their id>`, in
`storage/agent/ssh/people/`. Every SSH computer that existed then keeps its
person's keyring in `computers.ssh_keyring`, so nothing on its machine
changes; its person's other agents still share that key and trust. Moving one
to its own key, and removing the shared line from the machine's
`authorized_keys`, is a later, deliberate step. Remaking such a computer gives
it the agent's own key, which then has to be added to the machine and its
host trusted again.

Before keys were per person, the install had one pair, in `storage/agent/ssh/`
itself. If one person used SSH computers then, that pair is still theirs
(`users.ssh_keyring` is `shared`, and their computers then carry `shared`), so
their machines keep working. If several did, nobody keeps it: each person adds
their new key to their machines and trusts them again, and whoever runs the
install removes the old key from those machines.

The sidecar runs in a container on Kamal's `kamal` network. To reach the
machine it runs on, give that network's gateway as the machine (`docker network
inspect kamal -f '{{(index .IPAM.Config 0).Gateway}}'`) and let the host's `sshd` accept that network alone. Docker's default
bridge (172.17.0.1, `host.docker.internal`) is the wrong network for it, and
often firewalled.

`agent/test/ssh-computers.test.mjs` runs pi-env and its daemon for real
against a stand-in `ssh` that plays the host key.

## Install-managed SSH

For a deliberate rollout to selected agents in one personal workspace, add
`configured_ssh` to `PI_DURABLE__COMPUTERS`, preserving the other kinds.
Set the following in trusted install configuration; none has a default.

| Setting (prefix `PI_DURABLE__CONFIGURED_SSH_`) | Value |
| --- | --- |
| `WORKSPACE_ID` | Exact personal workspace record ID. Shared workspaces are never eligible. |
| `AGENT_IDS` | Comma-separated agent record IDs in that workspace. No wildcard. |
| `HOST`, `USER` | SSH hostname (or IPv4 address) and Unix account. |
| `BASE` | Absolute remote directory, no trailing slash; components start with a letter, digit, `_` or `-`, and may also contain `.`. |
| `KEYRING` | Reference `configured-<name>`, never a key or path. The name is 1–48 lowercase letters, digits or hyphens and starts with a letter or digit. |

Nothing switches automatically. An eligible agent uses **Computer → Kind →
Install-managed SSH**, with the computer on. Its existing file and shell
tools run in `<base>/<agent-slug>`, where the slug is the agent's fixed,
install-unique email local part. The directory must already exist; the app
does not create or delete it. If scope or settings cease to match, Rails
sends no computer for that selection, not a fallback. The sidecar rechecks
the current assignment before using a saved SSH definition.

The sidecar expects `id_ed25519` and `known_hosts` in
`<AGENT_STORE parent>/ssh/configured/<keyring>/`. Provision them outside
the app, service-readable only (private key mode `0600`), separate from the
workspace. The independently verified host key in `known_hosts` uses the
alias `pi-env-<host>`. The sidecar does not make a key, enroll a host, or use
ambient SSH config for this kind. An unknown or changed host key stops the
connection; the manual SSH trust page cannot change this keyring.

A directory is a starting point, not a sandbox. These agents share the
configured Unix user's filesystem access and network. Use a dedicated,
unprivileged account with no access to install secrets or other workspaces.

## A screen beside SSH

Every agent whose computer is SSH, either kind, in any workspace, keeps its
Sprite for the screen: shell and file tools run on the SSH machine, the
browser and desktop on the conversation's Sprite (`Computer#retains_browser?`).
The install must offer `sprites`; a held computer or a paused agent has no
screen.

The agent's `desktop` and the workspace owner's **Open screen** use the
conversation's existing Sprite name. So do a saved sign-in's fill and a
card's (`list_saved_sign_ins`, `sign_in_with_saved_password`,
`ask_for_sign_in`, `pay_by_card`): the secret goes to that Sprite's
`browser` user, never to the SSH machine. If that name is missing, opening it
fails; Ajent never creates a Sprite on this path. An independently created
replacement with the same name will be accepted. No guest passes, browser
file transfers or `ask_outside_for_sign_in` are available.
Shell and file tools stay on the SSH machine, and no profile data is copied.

A Sprite stopped while idle is woken by the next screen call, and its relay
answers seconds before its browser does. So a desktop action or a visit on a
Sprite just woken first waits, up to 20 seconds, for the browser's DevTools to
answer, and otherwise fails with "The screen's browser did not start within
20 s" rather than visit nothing or capture a black screen. A check that could
not run at all (no node on the guest, say), or that never answered before its
socket timed out, is never taken for an answer: it fails with "The screen's
browser could not be checked". Only a relay that hangs up without a byte is
taken for an old one. A Sprite whose
relay predates the screen's scripts visits and captures nothing and says
"This computer's image is older than its screen tools, so nothing was done.
Ask an operator to update it." Waiting never helps there, and making the
computer again would lose its browser's sign-ins, so an operator updates its
image instead.

One rule decides which agents get a tool whose answer goes to the screen's
browser (`Tool.on_screen?`): only one whose computer has a screen
(`Computer#screen?`), a Sprite that is on or a retained browser.

## boxd

A third kind, not built: boxd's microVMs hibernate to disk and wake with
their processes, run Docker inside, limit egress per machine, and can be
self-hosted. Two questions come before any code, from its documentation and
SDK alone: whether it boots this app's computer image (`Dockerfile.agent`) or
needs a snapshot made from it, and whether its exec stream carries the
daemon's stdin (otherwise the Sprite relay, on its public HTTPS port, behind
the relay's secret). Its empty egress list means unrestricted, so "no
internet" needs an address that goes nowhere.

## Named computer pilot (offline)

One agent with a working default can declare one additional Boxd computer.
In the offline fixture, a `read`, `write`, `edit` or `bash` call may give
its exact `computer` name. Omit the name to use the conversation’s usual
computer, just as before. A bad or unavailable name never falls back.
Screens, uploads, command connectors, notes and other tools stay on the
default. Oversized results from an explicit file or shell call stay on
the computer that ran it.

The two pilot definition settings default to blank. Even a definition that
names a computer cannot open it without an admitted sidecar transport bound
to that exact agent, owner and machine. The fixture injects a stub and checks:

- one machine, sized to 1 vCPU and 4 GiB;
- hibernation requested after 900 seconds of network inactivity;
- concurrent requests share one open attempt; an unknown outcome is not retried.

There is no Boxd network client or activation path for a production install
in this slice. Do not set the pilot fields on a deployed app. Hibernation is
not a spending limit. Live admission, custody and all-in limits need their
own review.
