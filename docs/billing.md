# Billing: who pays, and what was used

Every model call an agent makes is counted against the workspace and agent
that made it, and the workspace whose account it is billed to. A workspace's
members see the counts on its Usage page. No money moves: there are no
invoices, no payment provider and no prices beyond the estimates the app
already shows.

## Who pays

A workspace is billed to one of three (`workspaces.payer_id`):

- **The install**, when nobody has chosen. This is every workspace until its
  owner chooses, and it is how every call was billed before.
- **The workspace itself.**
- **Another workspace**, chosen explicitly. Only someone who owns both
  chooses it, so no workspace is billed for another's calls without its
  owner's choice. Nothing falls back silently to another payer.

The workspace's owner chooses under Billing on the workspace's page, or under
Who pays on its Usage page. Members see who pays and cannot change it. A
change applies to calls from then on; calls already counted keep the payer
they had.

The payer is a record of whose account the calls are billed to. The calls
still run on the install's own model subscriptions and keys (`/subscriptions`,
`docs/agent.md`), which every workspace shares today. A workspace with model
accounts of its own, and an agent or a model with a payer of its own (#41's
agent and per-model levels), are still to come; for now a workspace's payer
covers all of its agents and models.

## What is counted

Each `ModelUsage` record says what one model, or one tool, used in one run or
one background helper:

- the workspace and the agent that made the calls, with the agent's name as it
  was (the record outlives the agent);
- the thread, or the background helper;
- the payer then (none for the install);
- the model (`provider/model`, so a subscription and an API key are told
  apart) or the tool (`web_search`, and `subagent` for a helper that worked in
  the foreground, whichever model it ran on); a background helper's calls are
  under the model it ran on, which may be lighter or stronger than its
  agent's (docs/agent.md, "A helper's model");
- tokens read fresh, written, read from the prompt cache and written to it,
  and their total;
- the cost at the model's API prices, where the catalogue has them: an
  estimate, never a bill. A subscription is not billed per token.

It is counted from the sidecar's running totals for each model and tool
(`docs/design/CONTRACT.md`): at the end of each run, and when a page looks at
the thread, Rails records what each added since the last report it recorded
(`Conversation::Metering`). A report repeated or late adds nothing. This
counts every request of the run: the agent's replies, summaries of earlier
messages (and a fallback model's, under its own model), web searches and
helpers in the foreground. A background helper, which its thread's totals
never count, is recorded once, when it ends (workflow steps are background
helpers).

## Filed by client file

An agent whose work is for clients can label usage with the client file or
matter it is about. The tool is `file_under(label)` (`Tool::FileUnder`),
picked one by one in an agent's Tools and looked up rather than declared,
so it adds nothing to the tool count. Call it before working on the matter.

- It files the thread under the label, stripped of spaces and cut to 100
  characters (`conversations.filed_under`). A blank label stops filing.
- It asks nobody and reaches nobody: it is bookkeeping on the agent's own
  thread.
- Each usage row from the conversation takes the label the conversation has
  when Rails writes the row. Setting or clearing the label never fills in or
  relabels old rows.
- A background helper gets its own copy of the conversation's label when it
  starts. Its usage takes that copy, not the conversation's current label,
  even if the helper reports after the conversation changes or clears it.
- Usage written without a label stays blank and appears as **untagged** in
  the By file table. The conversation clears its label when the run ends.

The label is the agent's word only. Nothing checks it against a list of
files or guesses it from the text. Usage recorded before this feature is
untagged.

## What is not counted

- What a thread used before metering began. A thread that had used something
  with nothing recorded starts its count at its next report, rather than
  putting its whole history in this month.
- A background helper that was cancelled or lost: the sidecar reports no
  usage for it.
- Usage the sidecar reports while Rails cannot take it, beyond what the next
  report brings. A run's frame that never arrives is caught up by the next
  run or page load, attributed to the payer at that time.
- Anything outside the models, except the separate pilot ledger below.

## The Usage page

`/workspaces/:id/usage`, under Settings and on a shared workspace's page, for
its members alone. It shows this month and last (by the install's clock, UTC), in
all, by agent, by model or tool, by who paid, and by file. It shows only the
workspace's own agents' usage: never another workspace's, even one it pays for
or one its owner also owns.

The By file table has a row for each label (above), and one, "untagged", for
usage filed under nothing. Its columns lead with the estimated cost, then the
total tokens, the input and the output. A cost shows as a dash where the
model has no prices.

Optional From and To dates (`?from=2026-11-01&to=2026-11-15`) show those days
instead of this month and last, every table narrowed to them, from the start
of the first day to the end of the last. Either may be left empty for a range
open at that end; with neither, the page is as before. This is a view of the
records, not a bill per client.

## Pilot usage and limits

The pilot ledger keeps separate monthly USD ceilings of $50 for voice and
$50 for computing for the pilot agent. The Usage page shows settled charges
for the current UTC month, outstanding reservations, and the 50% and 80%
alerts. `Agent::PilotBudget#brief_line` is the shorter usage line. A blank
ledger changes nothing on existing installs.

Before starting a paid operation, an adapter must commit a reservation for
a known maximum charge in USD cents, with a stable operation ID. No
reservation, no operation. Settle only after a final charge or proof of no
charge; an unknown result keeps its reservation. Duplicate IDs do not
authorize another start. An unresolved hold crosses the month boundary
as a block, not new headroom. A charge over its reservation is recorded
and blocks further spending in that category.

This source slice does not connect to a provider or turn on the pilot.
The ledger cannot stop an unbounded provider charge. An adapter must be
able to enforce its maximum for the **entire** operation, including
ongoing compute storage or a call's side work, or refuse to start.
