# Adding an agent

## Before you start

Ask the install's operators before taking any action reserved for an owner.
A one-time check that no release is running does not reserve a window.
Confirm with the install's operator that no release is running or will start
before the onboarding write is complete. Take a fresh
[backup](../ops/backup/README.md) of the target install before writing. A
backup from an evaluation copy does not cover it.

## Create the agent

- **New agent.** On **Agents**, choose **New agent here** from the intended
  workspace's menu. Enter the name and choose **Start**. The optional purpose
  is added to the starter instructions; it does not replace them. To set the
  exact instructions, save them in the agent's **Instructions** settings.
  To set its reporting line, the workspace owner chooses **Move in reporting
  tree…** from the agent's menu, picks **Reports to**, then chooses **Move
  agent**. See [Reporting tree](reporting-tree.md). Plain creation
  (`User#start_agent`) creates no setup record, does not deduplicate retries,
  and has no setup undo.
- **Owner-approved local setup.** In the workspace, the owner opens **Agent
  setups → Authorize a setup**, selects a named workspace member as operator
  and an active manager in that workspace, enters the agent's name, exact
  instructions and written authorization, then chooses **Record
  authorization**. The named operator opens that record and chooses **Create
  approved agent**. It creates one agent with the recorded instructions and
  reporting line. Replay protection and setup undo belong to
  `Workspace::AgentSetup`. A request ID identifies the setup within its
  workspace. An authorized retry of the same setup returns the existing agent.
  The owner can revoke the authorization without deleting the agent. **Undo
  setup without deleting** removes the reporting line and archives the thread
  only if the setup is still reversible, including an unused thread and an
  unchanged name, instructions and manager. If the setup is no longer
  reversible, leave the agent in place and have the owner revoke the
  authorization. Any removal is a separate owner decision. Creating the agent
  does not send a first message or join Concourse.

Read back the saved name, workspace, instructions and manager from the agent
and its reporting line. For an approved setup, compare them with the setup
record and confirm it shows **Setup completed**. In **Tools**, check what the
agent will have available: at most 64 tool definitions are declared to the
runner per agent turn. This is not a cap on all tools the agent can find by
lookup. The lookup tools themselves count when declared.

## First turn

For an agent created through an approved setup, use the current manager's
**Brief report** (`brief_report`) for the first message. Enable the tool and
have the workspace owner approve the exact first message, even under
**Approve everything**. The message goes to the unused report under the
manager's own name, without Concourse. An untrusted operator relay does not
count as approval and must not stand in for this handoff.
**Accepted by the runner** is a receipt, not an answer. **Prepared; acceptance
not confirmed** is not a receipt. The local briefing was added in PR #454.

## Access the agent needs for its work

Give the agent only the read access its job needs, and check it can read the
actual evidence, repository or wiki page. You can attach evidence files in its
thread when it has a computer, or use a [connector](connectors.md) that exposes
the needed reads. Connectors can apply to the workspace or just one thread.
Repository reads need a connector that offers them and has access to the
repository. A reporting line does not grant access.

Where configured, the wiki is an install connector. Enable it for the
workspace only with the owner's authorization. The connector offers reads
and some writes; leave unneeded tools off, including write tools for read-only
work. Use a scoped key: what the agent can see depends on the key's permissions
in the wiki. This guide does not establish access to any page.

For a site the agent must read in its browser, use a [saved sign-in](passwords.md)
where supported. The browser fills the password on the matching site without
showing it to the model. A saved sign-in is not a Git credential or a grant
of repository access.

## Routines

The agent can propose its own routine with `add_routine`: a prompt and either
a repeating schedule or a single future time. Any workspace member authorized
to approve may approve the prompt and timing. Each proposal needs approval,
even under **Approve everything**, and offers no **Always** approval.

## Forge work

Use only a host-side wrapper that exposes fixed, approved forge operations for
source-control work. Never give the agent credentials. Core does not ship
that wrapper. Leave forge work with an operator rather than substituting a
token, a saved sign-in or unrestricted shell access.

## Network identity

Leave the new agent off Concourse by default. The manager handles any outward
Concourse correspondence as itself, using its own identity and usual send
approvals. This is not automatic forwarding and does not give the report a
network identity.

Only critical infrastructure roles should join directly. Use the audited
operator exchange, never a direct database write. Owner consent is the
one-tap approval card, held until the contract in Concourse PR #86 is agreed
(Core PR #474 (held)). Route the card through the install's owner
approval channel. The ordinary browser OAuth join is separate; the operator
exchange is not live. Leave direct membership off for this setup.

## Definition of done

- The agent answers in its own thread; a send receipt is not enough.
- Its [computer](computers.md) works. Confirm the agent is in the intended
  Rails workspace by ID.
- From the agent's computer, confirm it can write where intended and that
  it cannot use sudo or access Docker. These are checks of the computer's
  permissions, not guarantees made by creating the agent.
- The agent has delivered its first piece of work to the intended recipient
  or destination.

## Known gaps

These are not live in this onboarding path:

- **Computer first-message setup.** The local briefing can send text; it does
  not set up or verify a working computer as part of the first message.
  No tracking item yet.
- **Concourse admission by audited operator exchange.** The browser join is
  separate. See held Core PR #474 and the synthetic contract in Concourse
  PR #86. Neither is a live onboarding path.
- **Share packet.** There is no onboarding share packet. The phone's Share
  sheet is a different feature. No tracking item yet.
- **Host-side forge wrapper.** Core does not ship fixed-verb forge access.
  See #466, #467 and #472 for tracking, not a live onboarding path.
