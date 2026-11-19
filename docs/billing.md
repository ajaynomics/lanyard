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

## What is not counted

- What a thread used before metering began. A thread that had used something
  with nothing recorded starts its count at its next report, rather than
  putting its whole history in this month.
- A background helper that was cancelled or lost: the sidecar reports no
  usage for it.
- Usage the sidecar reports while Rails cannot take it, beyond what the next
  report brings. A run's frame that never arrives is caught up by the next
  run or page load, attributed to the payer at that time.
- Anything outside the models: computers, phone numbers, email and the like.

## The Usage page

`/workspaces/:id/usage`, under Settings and on a shared workspace's page, for
its members alone. It shows this month and last (by the install's clock, UTC), in
all, by agent, by model or tool, and by who paid. It shows only the
workspace's own agents' usage: never another workspace's, even one it pays for
or one its owner also owns.
