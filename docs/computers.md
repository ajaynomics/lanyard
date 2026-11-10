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
| A desktop and its browser | Yes: the screen, the desktop tool, saved sign-ins | No screen; `visit_website` runs the machine's own Chromium headless, if it has one | No screen |
| Limit its internet | Not by this app: no egress list is set (see below) | None: it is the machine's network | None, or none at all with `AGENT_SHELL_NETWORK=isolated` |
| Command connectors | Through the relay | Not yet | Here |
| Isolation | A microVM | None beyond the Unix user | None |

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
3. The machine lets the person's agents in: the person adds their own key,
   shown on that page, to the user's `~/.ssh/authorized_keys`, and trusts the
   machine's host key there once, after comparing its fingerprint with one
   they got another way (on the machine, `ssh-keygen -lf
   /etc/ssh/ssh_host_ed25519_key.pub`). A host key that changes is refused,
   never trusted from the page: whoever runs the install removes the old one
   from that person's `known_hosts` by hand.

Keys and trust are each person's own. Everyone on an install has their own key
pair and their own list of trusted hosts, so a machine one person set up is
closed to everyone else's agents: another person's agent would offer a key the
machine never saw, against hosts that person never trusted. A machine's user
that another person's agent already works as is refused outright, with a
message saying so. One person's own agents share their key and their trust.

An agent on SSH can do whatever its user can: read that user's files, run
its programs, reach its network. Give each agent a user of its own, with
nothing in its home but the agent's folder, and keep it out of the `docker`
group: on a Docker host that group is root.

pi-env does the SSH (`agent/ssh-computers.mjs`): no prompts, no forwarding,
strict host keys against the person's own `known_hosts` under a fixed alias,
and its small daemon copied to the user's `~/.pi/mobile/tools/`, checked by its
hash before every start. Connections are kept per person, user and machine.
Each person's key pair and trusted hosts live in
`storage/agent/ssh/people/person-<their id>/`, beside the sidecar's store, so
they travel with its backup. A key pair is made on first use; nobody pastes a
private key anywhere.

Before keys were per person, the install had one pair, in `storage/agent/ssh/`
itself. If one person used SSH computers then, that pair is still theirs
(`users.ssh_keyring` is `shared`), so their machines keep working. If several
did, nobody keeps it: each person adds their new key to their machines and
trusts them again, and whoever runs the install removes the old key from
those machines.

The sidecar runs in a container on Kamal's `kamal` network. To reach the
machine it runs on, give that network's gateway as the machine (`docker network
inspect kamal -f '{{(index .IPAM.Config 0).Gateway}}'`) and let the host's `sshd` accept that network alone. Docker's default
bridge (172.17.0.1, `host.docker.internal`) is the wrong network for it, and
often firewalled.

`agent/test/ssh-computers.test.mjs` runs pi-env and its daemon for real
against a stand-in `ssh` that plays the host key.

## boxd

A third kind, not built: boxd's microVMs hibernate to disk and wake with
their processes, run Docker inside, limit egress per machine, and can be
self-hosted. Two questions come before any code, from its documentation and
SDK alone: whether it boots this app's computer image (`Dockerfile.agent`) or
needs a snapshot made from it, and whether its exec stream carries the
daemon's stdin (otherwise the Sprite relay, on its public HTTPS port, behind
the relay's secret). Its empty egress list means unrestricted, so "no
internet" needs an address that goes nowhere.
