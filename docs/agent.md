# Agent sidecar (optional Pi Durable)

This app was generated with `PI_DURABLE=1`. It adds a Node sidecar running the
published `@earendil-works/pi-durable` runtime (pinned in
`agent/package-lock.json`) beside Falcon and Solid Queue. Rails stays the
application: people, agents, tools, approvals, the invocation ledger and every
domain record. The sidecar is generic infrastructure: it owns the durable
conversation and task state in its own SQLite store, runs the model, and
forwards every tool call to Rails.

```text
browser --CSRF--> Rails --SIDECAR_TOKEN--> sidecar (loopback or Unix socket, /v1/...)
                  Rails <--RAILS_TOKEN---- sidecar (/agent/accesses, /agent/invocations,
                                                    /agent/frames, /agent/syncs,
                                                    /agent/sign_ins, /agent/cards,
                                                    /agent/files, /agent/uploads,
                                                    /agent/helpers)
```

## What Rails supplies

- **Access.** `Agent::Access.for(agent)` names the person (`actorId`) and the
  agent (`workspaceId`) on every call. `POST /agent/accesses` answers for
  exactly that pair or refuses; an id in a URL or a sidecar request is a
  lookup key, never authority.
- **The definition.** Every submission carries `Agent#definition`:
  instructions, model, thinking level and each enabled tool's name,
  description and JSON Schema, plus a SHA-256 digest of all of it. The
  sidecar installs it as extension `bot.<digest>` (the name predates the rename
  and is kept, since it is stored in the sidecar), so an edit to an agent applies
  from the next message, and reinstalls the definitions still in use at boot.
- **Tools.** Each tool is a Ruby class in `Tool::Catalog`. The sidecar's tool
  is a forwarder: it posts the call to `/agent/invocations` and returns what
  Rails answers. Rails checks the arguments against the same schema, records
  the call in the `Invocation` ledger and runs it, or asks the person first.
  A person's connectors (MCP servers, `docs/connectors.md`) add tools named
  `mcp__<server>__<tool>`: Rails signs in, lists them (`McpServerRefreshJob`)
  and calls the server itself, so the sidecar sees one more forwarded tool
  and nothing else.
- **Files a call names.** A tool may list paths on the agent's computer
  (`Tool.reads_files`, declared as `files` with its limits): before the call,
  the sidecar reads them there (`agent/attachments.mjs`), never from its own
  disk, and posts each to `/agent/uploads`, kept against the call (`Upload`).
  A file missing, a folder or over a limit stops the call before Rails hears
  of it. `send_email` attaches them; its card names each file and its size,
  and the approval holds to their bytes. `UploadSweepJob` clears what no call
  used.
- **Files a call finds.** A call whose answer names a file (`file: true`,
  `Invocation#file?`: an attachment, a Drive file, a connector's file, an
  answer too long to read whole) has the sidecar fetch its bytes from
  `/agent/files` once and save them under `files/` on the agent's computer:
  a Sprite's home, or the folder an SSH or local computer works in
  (`agent/files.mjs`); another computer reads a PDF's words only if it has
  poppler (and tesseract for scans). There is no size
  limit: the bytes stream to the computer a few MiB at a time, under a
  partial name moved into place once whole, the fetch fails only when no
  bytes arrive for a minute, and a file
  is refused only when the computer has no room for it, in MB. See
  `docs/connectors.md`, "Files and PDFs".
- **Files mail brings.** An email's attachments are held on a ledger row of
  the mail's own, not a tool call's, and Rails asks the sidecar to save them
  (`POST /v1/conversations/:id/files`, with the computer as in the
  definition). Each is fetched and written as a call's files are; the answer
  says where each went or why not. See `docs/email.md`, "Attachments".
- **Files a person attaches.** The composer's paperclip, paste and drop take
  any file. A picture goes to the model to look at, as before; any other file
  (a PDF, a `.docx`, a spreadsheet) is held as mail's are, on a row of the
  send's own (`Conversation::Attachments`, task `composer`), and saved the same
  way (`Conversation::Handover`): under `~/files/<folder>/` in its own name,
  made safe, a second of one name kept beside it as `name (2).ext`. The words
  the agent reads end with an `<attached_files>` list of each file and where
  it was saved, or why not; the person's bubble leaves the list out and shows
  each file as a chip with its name and size, which downloads it. If the
  message is committed when the send answers, the sender gets that bubble
  in the response too, so a gap in live updates does not leave a chip that
  cannot be downloaded. The bytes stay with the send
  (`Conversation::Submission#files`) and then its message
  (`Message#files`), reached only through that thread (`ReachableBlobs`). Up
  to three files of 25 MB each go with one message (`Conversation::FILES_PER_MESSAGE`,
  `FILE_BYTES`), so a full message stays under Cloudflare's 100 MB a request;
  over either, the composer says so and nothing is sent. The files are saved
  before the send is answered, so the proxy in front waits up to 120 seconds
  for it (`response_timeout` in `config/deploy.example.yml`), not
  kamal-proxy's default 30.

## One send, one envelope

`Conversation::Submission` owns each explicit send, unique by conversation
and request ID. It binds the original words, picture bytes, attached files,
busy mode and source to an input digest. Before contacting the sidecar it prepares and
persists the exact JSON body: expanded words, the agent definition,
channel timestamp, canvas-version references, cancellation notices and date.
Preparation publishes under a short database lock; neither conversation
admission nor sending holds that lock across HTTP.

A failed response is not evidence that the sidecar refused the send: it
goes on with a request Rails stopped waiting for, as a busy one may take
longer than the client's ten seconds. A send that got no answer (the read
timed out or the connection dropped, category `no_answer`) is asked once
more under the same ID, which the sidecar answers from its record, so one it
took is reported delivered; a second silence raises an error that says the
same ID is safe to send again. Never mint a new ID to retry. An
explicit retry sends the same words and context under the same ID, even
after midnight or changes to prompts, skills and documents. Only the agent
definition goes as it is at that moment: the sidecar applies whatever
definition a send carries, so an old one would put back instructions or tools
changed since (the sidecar's duplicate check does not count it). Different
original input under that ID is a conflict, not an excuse to mint another ID.
A picture the model cannot see is refused before the sidecar admits the send,
so its envelope is dropped and words only may go under the same ID. No job or
reconnect handler sends a saved draft.
Helpers and workflow runs retain their existing report retries, with their
presentation generated only when the first envelope is prepared.

The receipt is saved before context bookkeeping. A retry of an accepted send
returns that receipt without dispatching or inventing activity. Bookkeeping
can resume after a crash: only the captured document versions and cancelled
helper/run IDs are acknowledged. Later edits remain pending, and older
acknowledgments never regress a newer seen version or date. A later summary
or time-zone change leaves its date notice pending. Once acceptance and
bookkeeping are durable, duplicate payload/picture bodies are removed; input
and payload digests, context references and the receipt remain. One the
sidecar answered as `queued` keeps its body while it waits there, so a pause
can hold it (below); the next snapshot that no longer lists it lets it go
(`Conversation#refresh_status!`). Pending
payloads use Rails' existing attribute encryption and are filtered on record
inspection.

The original person's words remain limited to 65,536 bytes; pictures retain
their own limits. The final expanded text and all notices together must fit
65,536 UTF-16 units. Expanded words are not cut. Every changed document gets
at least its read-document pointer, with fuller diffs only in the remaining
room. If mandatory context cannot fit, a typed refusal leaves it pending and
restores the draft/pictures. Turbo keeps the same request ID; ordinary HTML
stages an owned, one-day `Share` with that ID. JSON says `too_large` (422) or
`conflict` (409), rather than pretending the sidecar is unavailable.
A message from outside (mail, a text, Concourse, Campfire, a helper's or a
workflow's answer) is different: nobody is there to shorten it, and a
refusal would come back on every retry. It is cut to fit beside its notices
(60,000 units at most) and ends with `Conversation::CUT`, so the agent knows it has only part. A changed
message under an ID already sent is refused as a conflict; mail, Concourse
and routines log it and go on, Campfire and workflow runs retry, and a
helper's report answers 503 so the sidecar tells it again.

The migration is additive: existing threads and shares do not change and
older writers still work. The envelope guarantee starts with updated
writers. An old in-flight ID has no original envelope to reconstruct and
can still meet the sidecar's conflict guard. Operators should quiesce old
writers during adoption and check earlier uncertain sends in the committed
transcript; the app never disguises a conflict by resending under a fresh ID.

## The prompt cache

The sidecar sends what pi sends, so the provider's prompt cache holds as it
does in pi: the same session id on every request of a thread, the default
five-minute retention, and every change to the agent (its instructions, its
notes file, its tools, a connector's) written by pi-durable as a later
system message, which Claude 5 takes mid-conversation without touching the
cached prefix. Nothing app-owned is in the prompt per request: the time is a
tool (`current_time`), the notes file is read once per run, and tools are
declared in a fixed order.

The date is told as pi tells it (pi 0.80.7): never in the system prompt, but
at the end of the newest message, once a day in the agent's zone and again
after a summary (`Conversation#date_note`, `conversations.dated_on`):
"Current date: 2026-11-10 (Tuesday), in UTC. For the time, use current_time."
It is new words at the end, so the cached prefix holds; no view shows it.
Each message from someone else (Concourse, Campfire, mail, texts, a routine)
says when it was written, from the channel's own time, or when it arrived:
"Sent 2026-11-10 12:01 PST (20:01Z)" (`Conversation.received`).
The answers of helpers and workflows, and a peer's answer on a Concourse
task the agent sent itself, steer: one that arrives while the
agent works goes in at its next step, between tool calls, not once its turn
ends. A call already running finishes first. Each says it doesn't
replace the agent's task unless it says so or clearly implies it
(`Conversation::STEERED`). Automated mail (auto-replies, bounces, lists,
no-reply senders: `ReceivedMail::Automated`), mail found in a mailbox the
agent only reads, and routines wait for the turn to end.

### The inbox: one rule for every channel

A message from someone, on any channel (Concourse mail, email, texts,
Campfire, Telegram), goes by one rule, applied where every channel delivers
(`Conversation#receive`, #85). The agent's own person steers. Anyone else's
waits in the agent's inbox for its turn to end, or until it takes it in
sooner, unless it can't wait (`Conversation::Urgency`), by plain rules, never
a model: its sender's mail program marked it urgent (`Importance: high`,
`Priority: urgent`, `X-Priority` 1 or 2), or its words open with "urgent",
"stop" or "asap" (after any @mention of the bot). A correction or a "stop" is
still read at the next step. The agent's own person is known by their email
address on email, and by the name the channel shows on Campfire and Telegram
(`User#goes_by?`). Mail may be forged and anyone may show any name: these
rules change only when a message is read, never what the agent may do with it.

Which messages reach the agent at all is each channel's own rule, decided
before this one: a Telegram group's post, for one, reaches it only when it
mentions or answers the bot (#189). A mention from anyone but the agent's own
person then waits in the inbox like any other.

The inbox is pi-durable's own waiting list, so nothing new is stored, the
person sees and controls those messages as any other waiting message, and
pausing holds them. While one waits, the agent is told at its next step,
between tool calls: who sent it, how it starts, how many from others wait,
and how to take them in sooner ("[Waiting in your inbox: Concourse mail from
acme/sam, starting "Rome, not Paris?". 1 message from others waits. …]",
`agent/waiting.mjs`). The note is a write placed at the next boundary and
kept, so the cached prefix holds, and Rails never shows it (`entryView`).
`waiting_messages` (`Tool::WaitingMessages`), a tool every agent looks up
rather than carries, lists them with an id each, and with `take` (ids, or
"all") makes them steers, read after the step it is called in, in the order
they came. The person's own waiting words are not the agent's to take.
It asks the sidecar, so it runs as an outside call (`InvocationCallJob`),
never inside SQLite's write lock.

The person's own words steer unless he chooses Queue: a message from the
Watch or a notice's Reply, which choose no mode, steers too
(`SubmissionsController`, `Conversation#submit`).

What piled up while the agent worked goes in together, as one batch (#85):
at the end of a step every waiting steer, and when a turn would end every
waiting message, in the inbox's order (pi-durable's `steeringMode` and
`followUpMode` both `all`). The first of a batch says how many there are and
from whom, for example "[3 new messages, in order: 1 from the person you work
for, 2 Concourse mail.]", counting each by the channel Rails marks it with
(`agent/batches.mjs`). Those words are added to each model request, not
stored: the thread keeps each message as it was sent. A boundary places its
messages with one timestamp, so the same history always gets the same words
and the cached prefix holds. The rules are plain (who sent it, by which
channel); no model decides.

The person's own steer does not wait behind everyone else's: one he types (`Conversation#submit`,
whose payload says `fromPerson`; mail arriving by `Conversation#receive` never
does) is marked so on its waiting item and placed after his last waiting steer,
or at the front of the queue (`placeOwn` in `agent/runtime.mjs`), so he comes
first in the batch. It is marked
and moved in one commit, so the same request again moves nothing. Follow-ups
keep their place.

Until the agent takes one in, every waiting message, the person's or anyone
else's, can be switched between steer and queue, sent now (made a steer and
put at the front) or moved one place up or down; only the person's own can
be edited or withdrawn, since someone else's is answered, never dropped. The
list is pi-durable's inbox (`pi.inbox`), whose boundaries take the person's
items in the order of its `items`; so each control is one `harness.commit`
on that list (`changeQueued`, `moveQueued`; writes are never moved or shown),
the message keeps its id and its words, and it is taken in exactly once, in
the new order, a restart included (`agent/test/parity.test.mjs`). Who sent it,
and a Concourse task to reply to, are in those words, so a switched or moved
message still gets its reply where it should. One already taken in answers
`changed: false` or `moved: false`, and the page says the agent has read it.
While the agent is paused the list holds what it was sent instead, and any of
those may be dropped ("Pausing an agent", below).

Stop ends the reply in progress, including its running commands. Messages
still waiting in the inbox keep their place and go in with the next delivery.
A steer already taken into the stopped reply is part of that reply.

One exception, `agent/current-instructions.mjs`: when a thread's agent has a
new identity ("New agent from here"), its requests are sent with one leading
prompt, the new name first, which spends that thread's cache once and again
on each later change until compaction. A model switch spends it too, as it
does in pi: the cache is per model.

### Who said it

Each message keeps its speaker in the sidecar's store, not in its words. Rails
sends its author with it: `author: { userId }` for a person's own
(`Conversation#submit`, the signed-in person) and `{ sender }` for a channel's
message whose sender is known (`Conversation#receive`, by
`Message.sender_named`; a routine, helper, workflow or handed-back card has
none). The sidecar places the message as pi-durable's own input entry
(`entry: { kind, data }` on the submission) of kind `app.message`
(`MessageEntry`, `agent/state.mjs`) instead of `pi.user`, with its request id
and author in its data; the model reads the same user message. `entries` gives
both with the message, and Rails' copy keeps them (`messages.request_id`,
`author_id`, `sender`), so a restarted sidecar or `Conversation#resync!` credits
each message from its entry: two people's identical words stay apart, and a
person's words shaped like mail stay theirs. A message stored before has no
request id and is still read from its words (`Message#incoming`). Another
person's author is part of the request: the same request id from someone else
is refused as a conflict.

### Steers and cards

pi places steers only once every call of the step has ended, so a call
waiting on a person's card would hold every message behind it: on 15
November an approval waited 87 minutes and seven messages with it. So an
approval card does not hold the step. While the agent's own call, or a call
from a code mode script of its own (not a helper's), waits on a person and
any message is queued for the agent, the call asks Rails, once, to take its
card back (`handBack`, `agent/extensions.mjs`). For an approval
(`Invocation#hands_back?`) Rails marks the call `handed_back_at` and answers
`handedBack`; the call ends, telling the model the card is still open and not
to call again, and the messages are read at the next step, the person's own
first as always. A script's call gets that same answer as its result and the
script carries on, so the script, and with it the step, ends rather than
waiting; a script that drops the result does not pass that answer on, but
the agent is still told how the card ended, below. With nothing queued, a
script's call waits for the person as before.

The card stays open. If the person allows it, Rails runs the call once,
itself (`InvocationWakeJob` moves it on instead of ringing the sidecar), and
tells the agent how it ended: a steer from "Approval", request id
`invocation:<id>`, with the result, the denial, or why it did not run
(`Invocation#report`, `InvocationReportJob`). A card nobody answers ends at
its deadline (`Invocation.settle_handed_back`, every minute) and is told the
same way. The ledger still gates it: one row per call, run only from
`approved`, and a replay after a crash gets `handedBack` until the call
ends, then its recorded result. `agent/test/runtime.test.mjs` and
`test/integration/handed_back_cards_test.rb` hold this.

**Taking a card back.** An agent that has replaced a waiting call, or settled
it another way, withdraws its card with `withdraw_card(card_id)`, looked up
rather than core, which every agent has: the card closes, reads "Withdrawn"
in the thread, leaves Needs you, and the call never runs. Rails names the card
in the answer that handed it back (`card`, "Its card is \<id\>"), which is how
the agent knows its id. It takes back only an approval card of a call of its
own or of a script it ran, and only while it is still waiting: a helper's, a
question (`withdraw_question`), a saved sign-in, a payment, and one already
allowed, declined or expired are all refused, with the reason. Withdrawing
asks nobody, because it only ever takes a pending action away.

**A withdrawn card can never be allowed.** The withdrawal and a person's
decision take the same row lock (`Invocation#withdraw!`,
`Invocation#settle_person`), so an approval already on its way — from a page
left open, the phone's Needs you, the Watch, or a notification — finds the
card closed and is refused, and nothing is sent. The real miss it comes from
(#251): a replacement send card went up beside one still waiting, both were
allowed, and two near-identical emails went.
`test/integration/withdrawn_cards_test.rb` holds this.

A question, a saved sign-in, a payment, a file to save, and any card on a
helper's call (or a script a helper ran) still hold the step until answered:
the agent waits for a question's answer, a helper's result is the helper's,
and the others need the sidecar once they run. Rails answers those `waiting`, and the queued list says a steer waits
for the card (`Conversation#held_by_card?`).

### Questions asked without waiting

A question holds the step only when the agent needs its answer to go on.
`ask_person` with `wait: false` (#84) does not wait at all: Rails puts the
card in Needs you, marks the call handed back from the start, and answers
`done` at once with the question's id, `question_id`, and when it closes
(`Tool::AskPerson#asked`, `Invocation#asked_later?`). A replay gets the
same, however the card has ended since. The agent carries on.

When the person answers, Rails finishes the call itself, as it does a
handed-back approval, and tells the agent as a steer from "Question", from
"your question <id>", request id `invocation:<id>`, with the answer; the
agent decides whether it still matters (`Invocation#report_question`).
Unanswered, the card closes at its deadline, by default a day,
`expires_in_hours` up to seven days, and the agent is told the same way.
An agent that settled it itself withdraws it with `withdraw_question(question_id)`,
looked up rather than core, which every agent with `ask_person` has: the card
closes, can no longer be answered, and nothing is told back. A helper's
question always waits, since its answer would reach an agent that never
asked. A question is not an approval: it asks wherever the install allows
everything, and its answer comes in untrusted, as any card's report does.
`test/integration/async_questions_test.rb` holds this.

## Pausing an agent

The person can pause any agent, in its settings (`resource :pause` on agents:
create pauses, destroy resumes). The agent list, the sidebar and its thread say
so; each pause and resume is logged (Rails' log and an Ahoy event). Two
columns (`Agent::Pausable`): `agents.paused_at` marks what is held, and
`agents.resumed_at` lets a resumed agent run while what it held is still being
sent to it.

- **No turn, no tokens.** While paused, `POST /agent/accesses` answers
  `{ allowed: false, paused: true }`. The sidecar already asks it before every
  tool call (the `omakase.authority` `beforeTool` hook, whose throw blocks the
  call) and before every model request (`reserveRequest`, before the provider
  is reached). A call already running ends; the next call is blocked, and the
  model reads "Tool call blocked: paused_by_owner", not `access_denied`; the
  next model request is refused, which ends the run with the reason
  `paused_by_owner`. Rails records that end as idle, not an error, then and
  after the resume (`Conversation::Activity::PAUSED`). Stop (`cancel`) is not
  used: it would cancel the run's waits, but on pause approvals in flight stay
  pending (`agent/test/pause.test.mjs`). The interrupted turn does not carry
  on by itself after a resume; the next message, a held one included, starts one.
- **Helpers and workflows** are refused too: a helper's requests are its
  agent's, so a helper running at the pause fails at its next step, and a
  workflow step under way fails with it. Neither is restarted on resume; a
  workflow starts no new step while paused.
- **Approving a card** waiting on the person runs its tool even while the agent
  is paused: `/agent/invocations` does not ask about the pause, since the
  approval is the person's own act. A card handed back to Rails runs too;
  what Rails tells the agent of it is held with the rest.
- **Held messages.** `Conversation::Submission#deliver` returns early, unsent,
  for an envelope prepared since the pause: the person's own messages,
  Campfire, Concourse, email and texts, helpers' and workflows' answers. The
  held list is the thread's unaccepted envelopes created at or after
  `paused_at`, in the order they were sent (`Conversation#held`, by
  `created_at`); there is no other table. A copy of one sent before the pause
  (below) is dated at the pause, so it goes before whatever was held after it.
  A send that failed before the pause is not held, and the resume never sends
  it. The waiting list (`conversations/_queued`) shows them below the
  sidecar's own, each with Drop while paused, and Resume, which sends them all. A send the
  person makes while paused shows no typing dots.
- **Old branch threads** hold nothing (`Conversation#holding_since` is nil for
  them; branches are no longer made). A send to one while its agent is
  paused is refused (`Submission::Paused`: "Resume it, then send again"), and
  the same send goes once the agent is resumed. A helper's answer there is
  refused with 503, and the sidecar tells it again later.
- **What was waiting.** Pausing takes back what the sidecar had queued, in its
  order (`Conversation#hold_queued`): for each item, a copy of its envelope is
  made under `<request id>:held`, in the mode it waited in, then the item is
  withdrawn (`withdrawQueued`). pi-durable keeps the first submission of each
  request id, a withdrawn one too, so the same id sent again would answer
  `unanswered` and never be read; the copy's own id is read once. The copy comes
  first: a crash between leaves both, and the next pull-back withdraws the item
  under the same copy. One the agent took in meanwhile is not held. The pause
  also enqueues `ConversationHoldingJob`, a few seconds on, which pulls back
  once more, for a send that was under way as the pause was saved. The resume's
  job pulls back the same way before it sends anything, so a resume within
  those seconds misses nothing: one path, `hold_queued`, then `deliver_held`.
  Once resumed it takes back only what was accepted before `resumed_at`, never
  what the resume itself sent. A send the
  sidecar accepted at or after `paused_at` and no longer queues was taken in
  by a run the pause refused at its first step, so it is held again as a copy
  too, and the agent sees it twice in its history. Such a send keeps its body
  while the agent holds (`Submission#deliver!`, `Conversation#refresh_status!`),
  for the copy. If the sidecar can't be reached, the pause stands (no tokens
  are spent) and the job retries.
- **Resuming** lets the agent run at once (`resumed_at`) and enqueues
  `ConversationHoldingJob`, which sends the held envelopes in order, each as
  a retry of its own would, in a loop until none is left: a message that comes
  meanwhile is held too and goes after them, sent by the same job (it adds
  none of its own). Then, in the same transaction as a last look that
  nothing new is held, it clears `paused_at` (`Conversation#deliver_held`).
  One the sidecar refuses for good, for what it is (400, 404 no such
  conversation, 409, 413, or 422 such as `tool_limit`), or the app's own
  refusals, is logged, set aside unsent, and
  the rest go on; the person is told beside the waiting list, in the words a
  refused send of theirs would get ("A held message wasn't sent: ..."). Any
  other error, a wrong token (401, 403) or a busy sidecar (429) among them,
  is said there too ("Trying again in a minute"), and the job
  retries it a minute on, without end; it is safe to run again: an
  unreachable sidecar, an unexpected error or a restart of the jobs process
  leaves the rest held until it does; a send whose answer was lost goes
  again under its id and is read once. That note is live only: a reload
  shows it again at the next try, not before. A resume under way can't be paused or have a
  message dropped: Pause and Drop are hidden, Pause does nothing, and Drop is
  refused ("Too late to drop"), under the agent's lock, so a held message is
  never dropped as it is sent.
- **Routines** due while held hold one run each, however many slots pass
  (`Routine#waiting?`): each slot has its own request id, since a run moves
  `next_run_at` on, so the id alone would not stop a second. A one-off
  (`once_at`) due while held is held once and deleted; it runs on resume.
- **Senders.** A Concourse message held for a paused agent, received or taken
  back, answers its task `TASK_STATE_WORKING` "Agent paused: your message is
  held until its owner resumes it." The task stays open. Campfire and email
  senders are told nothing.
- **Dropping** a held message, only while paused, destroys its envelope. A Concourse message drops
  every held message of its task with it, and the task is answered once,
  `TASK_STATE_REJECTED`, "Dropped by the owner while the agent was paused."
  (the button asks first). A Campfire message or an email is only logged, by
  channel: nothing is posted, and no mail is ever sent by a pause, a resume or
  a drop.

## Processes

| Process | Command | Notes |
|---|---|---|
| web | `bin/falcon` | unchanged |
| jobs | `bin/jobs` | Solid Queue, its own role; tool calls an agent waits on have a worker of their own (`config/queue.yml`) |
| agent | `bin/agent` (production: `bin/agent-container`) | the sidecar; loopback `AGENT_PORT` (4397); exactly one per store |

`bin/dev` (`Procfile.dev`) starts web and agent in development, and `bin/jobs`
runs in a second terminal. In production each is its own Kamal role (below). `bin/agent` starts Node with
a clean environment: only the two transport tokens, its port, store path,
Rails URL, the provider keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`), the
subscriptions' files (`CLAUDE_SUBSCRIPTION_FILE`, `CHATGPT_SUBSCRIPTION_FILE`)
and their vault key, the
Sprites settings (`SPRITES_TOKEN`, `SPRITES_IMAGE`, `SPRITES_URL`, `SPRITES_IDLE_MS`),
`AGENT_MODEL_MODE`, `AGENT_EXECUTION_MODE`, `AGENT_COMPACT_AT_TOKENS`,
`AGENT_SHELL_NETWORK` and `AGENT_CONFIG` reach it, never the app's other
secrets.

The model pickers cache the sidecar's catalogue for ten minutes. In a
socket-based deploy the cache belongs to the socket that the ready sidecar
creates. When it takes over, the next picker load reads its catalogue
without waiting for the old cache to expire. Signing in or out still
forgets the current catalogue; other cache entries are left alone.

### Tool calls and the package patch

A model's tool calls in one message run at once, as pi's do, and their
results reach the model in the order it made the calls. A tool that shares
state declares `executionMode: 'sequential'` (`visit_website` and `desktop`
share the screen), and one such call makes its round run one call at a time.
pi's own `edit` and `write` queue changes to one file.

pi-durable 1.5.0 could leave such a round's turn waiting for ever, or its
parent completing (earendil-works/pi#11892), and `agent/patches.mjs`
patched it; 1.5.1 fixed it upstream and the patch is gone.
`agent/test/tool-calls.test.mjs` still runs 400 shuffled parallel rounds and
400 rounds of tools that start a helper, and fails on one hang.
`agent/patches.mjs` holds the fixes an installed package needs, today code
mode's images ("What a script gets from a tool", above): each is a literal
replacement applied after every `npm ci` (`bin/agent`, `bin/agent-test`, the
Dockerfile), and an upgrade that moves its code fails the build.

Under it, Rails has a safety net: the sidecar reports `stalled` when a run's
tasks, a helper's included, are there and none runs or sleeps, and
`ConversationRecoveryJob` (every minute) ends a run stalled for two minutes
(`Conversation::STALL_LIMIT`), as Stop would, saying why. The same sweep
rings the waits the sidecar still holds for calls already answered, and
fails an outside call left running a day after its run ended
(`Invocation.settle_abandoned`), logging each it settles.

### Summaries and a provider's refusal

The sidecar summarises a long conversation on its own at 180,000 tokens,
starting in the background at about 147k, and `/compact` asks for a summary at
any time (`agent/README.md`, Run policy).

Why 180,000: every model call reads the whole context again, mostly from the
prompt cache at a tenth of the input price, so the re-read is most of an
agent's cost. A summary costs a full-price read of what it summarises, its
output, and a rewrite of the cache after it. Over 14,670 replies of nine agents
(an install's copy, 8 to 12 November 2026), a summary came every 105 calls or
so, at about 234k tokens, and left about 67k (instructions and tools, the
summary and the recent messages); the context grew about 1,600 tokens a call.
With summaries near 150k instead, the average call reads about 110k tokens
instead of 150k and a summary comes about every 50 calls; counting the summaries,
a call costs about 5 to 8% less. That is close to the cheapest point: below
about 130k the extra summaries cost more than the smaller calls save.
`AGENT_COMPACT_AT_TOKENS` changes it.

The summary is a request to the conversation's own model. A provider may
refuse it for safety (Anthropic's `refusal`, say), however ordinary the
conversation, and Durable would ask again after nearly every turn. So the
sidecar asks once more of a fallback model (`summaryFallback` in the config
file, else the cheapest other offered model of the same provider whose
window is as large); a summary it writes ends with a line naming it, and
both requests count in usage under their own models. Refused there too, the
summary fails, no summary starts on its own for 30 minutes
(`limits.summaryBackoffMs`) while each turn goes on with the context it has,
and `/compact` still works. Under the thread Rails says the provider refused
(safety filter) and that switching model may help; a run that waited for the
summary stops with the same words (`compaction_refused`). The provider's
own words stay in the sidecar.

### Where a thread stands

Rails keeps two facts apart (`Conversation::Activity`). The run's
(`conversations.execution_status`) is the agent's own: a frame with
`busy: true` or a snapshot saying `running` or `waiting` (the run holding a
wait) makes it running; `busy: false`, or `done`, `cancelled` or `idle`,
makes it idle, or error with a failure, as `error` and `blocked` do; `stalled`
takes the recovery path above. A send makes it running only when the sidecar
accepts it for the first time; a retry that finds the send already accepted
(Conversation::Submission) never revives a run that ended. The snapshot and
frames leave background helpers out, so a helper's card never makes or keeps
the run going. Attention is the ledger's: an unexpired card waiting on the
person. The shown `status` is both: waiting while such a card waits, else the
run's. A card's arrival or answer works it out again
(`Invocation#show_progress`) and redraws the bar above the box, and the
list's row when the count of cards changes, but never changes the run.
A snapshot's `waiting` counts as running only while a call it waits on is
still open in the ledger. One whose every wait is on a call already answered
(succeeded, failed or denied) is a wait the call left behind, so the run is
`unknown`, not working (`Conversation::Activity.from_snapshot`), and each such
wait's doorbell is rung and logged (`Conversation::AnsweredWaits`): a call
still waiting asks again and takes its answer, and the sidecar settles a wait
whose call has ended. The next minute's sweep then reads where the run really
is. Since a call ends its waits however it ends (`agent/README.md`), these are
waits left by calls from before that rule, or a moment between an answer and
the call's next ask.
`unknown` is a run Rails can't vouch for, shown as "Checking run status";
`ConversationRecoveryJob` asks the sidecar about every running or unknown run
each minute, and a thread whose only news is a card waiting after its run
ended asks nothing. `status` stays a column, written with the run, for
readers from before `execution_status`: it holds only values they accept, so
an unknown run is stored as `running` and shown as unknown
(`Conversation#shown_status`). During a deploy, code from before may start a
run it records only in `status`; the sweep asks about those too, and their
end is told as any run's. A paused agent's run, refused at its next step,
ends idle, not in error ("Pausing an agent", above).

### What a script gets from a tool

A `codemode` script gets each tool's value: a tool with a schema (`read`,
`bash`) its object or text, any other its text. Two things are added here.

- **Pictures reach the model.** Screenshots from `desktop` and
  `visit_website` and images from connectors are part of a tool's answer,
  not its text. The last three images the script's calls returned follow
  its output, each saved to a file with its path beside it, as `image()`'s
  are. The model is told how many earlier ones were left out
  (`agent/patches.mjs`). The script still gets the same text or JSON.
- **The size limit applies to it too** (below): past it, the script's value
  is the JSON that says where the whole result is, never a cut copy. A
  script's `read` that stops at Durable's limit gets the same JSON, its
  `path` the file it read, to read on with `offset` and `limit`; a part it
  asks for with `offset` and `limit` is not cut. A PDF's words come back as
  far as they fit, all of them in `full_text` (`agent/files.mjs`).
  `agent/test/codemode-results.test.mjs` checks all of this.

### One size limit for every result

One tool result, the model's own call or a script's, may take **48 KiB
(49,152 bytes) or 2,000 lines** of text (`RESULT_MAX_BYTES` in
`agent/whole-results.mjs`; Rails' `DurableAssistants::ResultBytes::LIMIT`
is the same number, and `test/lib/result_bytes_test.rb` holds them equal).

Why 48 KiB: the smallest limit a result meets on its way is Durable's own,
51,200 bytes or 2,000 lines (pi-durable's `truncate.js`), past which it
keeps the start and drops the rest. That start was JSON that no longer
parsed: three agents on 16 November saw results fail at about 51 KB, and
screen actions at about 128 KB, with "Unterminated string in JSON"
(#192). 48 KiB leaves 3 KiB under it for what Durable adds after the
result (its notes). Nothing else on the way is smaller: the sidecar takes
1 MiB in a request from Rails and 32 MiB in a submission
(`agent/server.mjs`), a screen answer may be 16 MiB (`agent/desktop.mjs`,
`agent/computers.mjs`), the Sprite's relay limits only the action sent to
the screen (64 KiB, `agent/sprite-relay.mjs`), and neither Rails' sidecar
callbacks nor the deploy's proxy (`config/deploy.yml`) set a body limit.

Past the limit the whole result is saved, and in its place the call gets one
line of valid JSON:

    {"over_limit":true,"tool":"note","bytes":131234,"lines":1,"limit_bytes":49152,
     "path":"/home/agent/files/3f2a9c01b7/note-result.json","preview":"{\"messages\":...",
     "note":"note returned 131,234 bytes in 1 lines, over the limit ... read with offset and limit."}

- `path`: where the whole result is on the agent's computer: on a Sprite
  under `~/files`, in the call's folder, as a found file is; on another
  computer (this host's folder, an SSH one) under `files/` in its folder.
  `null` when the agent has no computer, or the computer would not take it;
  the note says which.
- `bytes` and `lines`: the whole result's size.
- `preview`: its first 1,000 characters.

Its pictures (a screenshot from `desktop`) follow the JSON as they were, as
they are not what is cut. A result under the limit is left exactly as it
was. An error stays an error. Three keep their own bounds: `codemode`
itself, whose output the script's token budget bounds and whose whole
output it saves to a file; the model's own `read`, a page of a file it
reads on with `offset` and `limit`; and `bash`, whose output Durable keeps
the end of and saves whole to a file, its path in `fullOutputPath`.

Without a computer the whole result is not kept anywhere: Durable's only
per-conversation store an agent can read is code mode's `store()`, which a
hook cannot write and which holds 256 KiB a value. The agent gets the size,
the start and a note to ask for less.

### Secret-shaped values in results

Masking is a backstop, not a permission: agents still never print secrets.
If a command, a page or a file shows one anyway, the model reads a mask in
its place, and a note says how many (`[masked 2 secret-shaped values]`, an
`info` diagnostic with code `masked`).

- **What is masked.** Known key prefixes keep the prefix (`sk-ant-[masked]`,
  `ghp_[masked]`, AWS, Slack, Google, GitLab, SendGrid, Duffel); a
  `PRIVATE KEY` block keeps its first line; a named value keeps its name
  (`API_KEY=[masked]`, `"password": "[masked]"`,
  `Authorization: Bearer [masked]`); and a run of 32 or more characters that
  mixes upper case, lower case and digits like a random key does.
- **What is not.** Hashes and other hex, UUIDs, ULIDs, ids made of
  timestamps, paths, pictures (a `data:` URI, base64 over 1 KB), plain links,
  and links on the install's own address (`APP__URL`, exactly that scheme,
  host and port), so the sign-in link `ask_outside_for_sign_in` makes goes
  through whole. A host that only looks like it is masked as any other.
- **The app's address.** Each side reads `APP__URL` from its own
  environment; Rails sends nothing new in an agent's definition, so a Rails
  and a sidecar of different releases still work together. Give the agent
  process `APP__URL` too (`bin/agent` passes it on; in a Kamal destination,
  set it in the agent role's `env`). Without it, or with something that is
  not a web address, the sidecar logs one warning at start and masks those
  links like any other; it still starts and every message goes through.
- **Where.** The sidecar masks every tool result the model reads, the
  agent's and its helpers', before it is kept (`agent/secret-mask.mjs`).
  A script's own calls get their values whole, since ids and hashes are its
  data; what the script returns or prints is masked. Rails masks what it
  sends as a message in place of a tool result: a handed-back card's result,
  a helper's or a workflow's answer, a sign-in link's or held email's report
  (`SecretShapes`, in `Conversation#receive`). What people send (mail,
  texts, Campfire, Telegram, Concourse) is theirs and is never masked.
- **One list.** Both read `config/secret_shapes.json`, patterns in the part
  of regular expressions JavaScript and Ruby share, and both suites hold
  them to the same answers, `test/fixtures/secret_shapes.json`.
- **Not covered.** Pictures (a secret on screen reaches the model as
  pixels), a secret split across lines or encoded, a short password with no
  name, history kept before this, and a result written after the restart
  limit, when Pi Durable runs no hooks.

### Several helpers from one script

A model's own `subagent` call waits for its helper. To run several side by
side, the agent starts them from one `codemode` script, which waits for all
of them together:

```js
const [a, b] = await Promise.all([
  tools.subagent({ task: 'Summarise the March invoices.' }),
  tools.subagent({ task: 'Summarise the April invoices.' })
]);
return [a, b].join('\n\n');
```

Each helper is a call of the script's (`<script call>/c1`, `/c2`), and its
own calls show under its line, and reach Rails, as `<script call>/c1/<call>`,
while it works. A script starts helpers in the foreground only:
`background: true` needs a call of the agent's own (below). Both are tested
(`agent/test/capabilities.test.mjs`, `agent/test/helpers-background.test.mjs`).

### A helper's model

A helper runs on the agent's own model and thinking unless its `subagent`
call, or a workflow's step (`run_workflow`'s `steps[].model` and `.thinking`),
names others: a model the agent's settings offer, by the name they show it
("Claude Haiku 5.5", or "Claude Haiku 5.5 · API key" where two share a name),
and a level that model supports. Nothing else is offered: a model this install
hasn't configured, or a level the model lacks, is refused with the choices,
and nothing is swapped in. Its line, its row in the Helpers panel and a
workflow step's row name what it ran on, "Claude Haiku 5.5 · Subscription ·
Low thinking"; a step names what it asked for until its helper reports. A
helper that asked for a model or level ends its answer saying what it ran on.

### Helpers in the background

`subagent` with `background: true` (`agent/subagent.mjs`) returns at once and
runs the helper under a Pi Durable background task the conversation owns
(`omakase.helper`). It is the same child as a helper in the foreground, with
the same tools and approvals, but it outlives the run that started it, so:

- **Stop leaves it running.** The agent's Stop aborts the run's own work, not
  a background helper; the person cancels a helper on its line
  (`POST /v1/conversations/:id/helper_cancellations`, which answers with what
  it had done). Rails answers any card it was waiting on for it, and tells the
  agent with whatever reaches it next, without a turn of its own.
- **The agent can check on it or cancel it.** `check_helper` (`Tool::CheckHelper`)
  reads what the helper last reported to Rails: working or how it ended, how
  many calls, and its latest. `cancel_helper` (`Tool::CancelHelper`) is the
  person's Cancel (`Helper#cancel`); its line then says the assistant cancelled
  it, and the agent is not told again. Both name the call that started it, and
  reach only the agent's own helpers in that conversation.
- **It can be told something while it works.** The agent's `message_helper`,
  naming the call that started it (the start says which), or the person's
  Message on its line (`POST /v1/conversations/:id/helper_messages`, which
  answers whether it took it) goes into the helper's own turn as a steer, read
  at its next step, and gives that turn a fresh request bound, as a steer to
  the agent does. A helper that has ended takes nothing and says so. One that
  was writing its answer reads it in a turn of its own, and that turn's answer
  is the one reported. Rails keeps the person's words on its line and tells
  the agent them with its answer.
- **The Helpers panel lists them.** Each agent's settings have its helpers
  (`/agents/:id/helpers`), and Settings has every agent's (`/helpers`): those
  working, newest first, with their newest step, then the last 25 that ended,
  each with a line of its answer or why it stopped, and a link to its thread.
  A working one has the same Message and Cancel as its line in the thread.
  Neither brings a page back: the change is shown by the broadcast it makes,
  so a page fetched meanwhile can't land over it (`RedrawnByBroadcast`).
  Workflows' runs are a section of their own below (Workflows below); a
  step's helper is listed within its run, not among the agent's own. As helpers report and runs move, the whole panel is
  broadcast and morphed in place (`ListedInHelpersPanel`), stamped with when
  it was drawn so one that arrives late is dropped; nothing polls. The
  thread's "2 helpers working" opens it, and counts a helper from its start
  (the result of the agent's call, or a workflow's step starting it), before
  it first reports.
- **It reports to Rails.** `POST /agent/helpers` says that it works and on
  what, what it is doing (at most once a second, best effort), and how it
  ended. Rails keeps it as a `Helper` and hands its answer, or why it
  stopped, to the conversation through `Conversation#receive`, once, by
  request id `helper:<call>`. A last report Rails can't take is told again,
  from five seconds doubling to ten minutes, for a day, across restarts.
- **One whose end never arrives is settled.** A helper still running in Rails
  that has reported nothing for ten minutes is asked about every minute
  (`ConversationRecoveryJob`, `Helper.settle_lost`;
  `GET /v1/conversations/:id/helpers?callId=`, which answers `running` or
  `terminal`, 404 for a helper it has no task for, and stops nothing). If the
  sidecar has its task as ended, or has none, its end report was lost: Rails
  settles it as failed, "lost". One quiet for three days (`Helper::QUIET`) is
  stopped in the sidecar and settled as failed, "quiet": a real helper is
  quiet at most a day while a call waits on a person and a day while its end
  report is retried. Each is logged; the agent is told it stopped without an
  answer, as for any failed helper; nothing is run again; the thread's count
  drops it. One the sidecar can't be asked about waits for the next minute.
  (one agent's helper 95, 2026-11-15, stayed "working" for 11 hours this way.)
- **It has bounds of its own.** At most 3 run in a conversation and 6 in the
  sidecar (`HELPERS_PER_CONVERSATION`, `HELPERS_PER_SIDECAR`); a start beyond
  that is refused to the agent. Its model requests count against its own
  `maxRequests`, not the run that started it. Only a call of the agent's own
  starts one: a script's call has no line on the page for it.
- **Deleting the agent stops them.** Its conversations ask the sidecar to
  cancel each helper still working before they go. One the sidecar can't be
  reached for runs on to its own bound, but Rails refuses every tool call and
  report it sends, the agent being gone.

### Workflows

An agent with helpers also has `run_workflow` (`Tool::RunWorkflow`): a job of
up to 10 steps, set out as a plain object, each step a background helper.

```js
await tools.run_workflow({ name: 'Hotels', kind: 'fan_out', steps: [
  { task: 'Find three hotels in Lisbon.' }, { task: 'Find three hotels in Porto.' }] });
```

`fan_out` gives every step to its own helper at once, as room allows (the
helper caps above); `pipeline` runs them in order, each helper given the
answer of the step before, and stops at a step that fails (the rest are
"Not run"). An optional `context` goes to every step. The call returns at
once, from the agent's own call or a script's; every answer reaches the agent
in one message when the last step ends (request id `workflow:<run>`).

Rails keeps it: `Workflow` (the definition), `Workflow::Run` (one execution)
and `Workflow::Step` (each step's task, state, answer and timing). Rails asks
the sidecar to start each step's helper (`POST
/v1/conversations/:id/helpers`), under a call named for the step
(`workflow-<run>-<position>`); the sidecar starts one helper per call, ever,
and answers 429 while the caps are full. The helper reports to
`/agent/helpers` like any other, as a `Helper`, but hands its answer to its
step instead of the thread. A run moves on in `WorkflowRunJob` (when it
starts, when a step ends, when any helper ends and makes room) and every
minute in `WorkflowSweepJob`, so a restart of the app or the sidecar delays a
run but never loses a step or starts one twice: a start the sidecar never
answered is asked for again, and a helper the sidecar started resumes with
it. A step the sidecar refuses outright fails, saying why.

The run is drawn on the line of the call that started it
(`workflow/runs/_run`, `workflow/steps/_step`), redrawn by broadcast as its
steps change; each step lists its helper's calls, and an approval its helper
waits on shows there. The person's Cancel workflow stops every helper at
work and the steps not started; the agent hears with its next message, as
for a cancelled helper. A helper can't start a workflow.

The Helpers panel lists runs too, under "Workflows running", newest first,
then the last 10 that ended under "Recent workflows" (`workflow/runs/_row`):
its name, agent and shape, steps done of all and the step at work (a
pipeline's) or how many work (a fan-out's), then how it ended (a pipeline's
last answer, the step that stopped and why, or what had finished before the
person cancelled it). A running one has Cancel workflow, and each of its
steps at work a Message for that step's helper, the same as for a helper of
the agent's own; a step has no Cancel of its own.

### Browser send approval (proof image only)

The separate `hold-proof` target in `Dockerfile.agent` holds the screen
browser's HTTPS `POST`, `PUT`, `PATCH` and `DELETE`, whether a person,
an agent or a script caused the request. It passes `GET` and `HEAD` and
does not cover shell or connector traffic. Only the browser UID can dial
the loopback proxy; its other network traffic is blocked. The proof image
requires working nftables and a guest tmpfs at boot. Chromium keeps its
sandbox, but its DevTools clients connect over a Unix socket instead of
asking the browser UID to use TCP.

The proxy holds the exact body and request target in the computer for up
to 90 seconds. It offers HTTP/1.1 only and refuses unreviewable writes,
including uploads and bodies larger than 64 KiB. The browser trusts a
throwaway CA in its NSS database only. The CA key file is removed at setup;
the key stays in the proxy's memory under the `hold` user, never in Rails,
the sidecar or a vault.

An explicit sidecar proof session (`listenForHeldPosts`) gives `HeldPosts`
a connected relay and a fixed conversation scope. It reads previews over
the authenticated relay and calls private `POST /agent/held_posts`.
The `outside_send` card shows the site, method, path and fields, with
recognisable secrets withheld. It has Allow once and Deny, never Always.
The sidecar reads Allow only once. It signs the decision for that exact
request, and only a live signed Allow can release it. An expired, reused
or changed decision cannot send anything. The card records the approval,
not delivery to the site.

`bin/check-hold-proof` exercises the proof image against a loopback site
with Docker networking off. The ordinary computer image and the way
agents choose computers do not change. This is not a rollout: the
published digest must pass the later real-computer run before anyone can
turn it on for agents. See [browser hold](design/browser-hold.md).

### Computers

Each conversation has its own computer: its file, shell and browser tools
(`read`, `write`, `edit`, `bash`, `visit_website`, and on a Sprite `desktop` and `browser_upload`)
run there. Rails' `Computer` record is the agent's template: whether its
conversations have one, which kind (`config/pi_durable.yml` lists the
kinds an environment may use) and whether the notes file is read. It reaches
the sidecar in the agent's definition, so turning it on or off applies from the
next message. The sidecar refuses a kind it cannot offer
(`computer_unavailable`). There is no table of computers: each one's name is
derived, and it is made the first time the conversation uses it. An agent made
with "New agent from here" is a new agent, so it starts with a fresh, empty computer. Archiving leaves the
computer asleep; nothing deletes it. Helpers share their conversation's computer.

A `bash` command runs at most 10 minutes unless the agent asks for longer,
and never more than 60: at the limit the computer ends the command and
everything it started, and the agent is told so with what it printed
(`agent/README.md`, "Run policy").

The conversation's notes file is `AGENTS.md` in its computer's home folder; each
conversation has its own (agent-wide memory stays in Rails' notes). The owner may drop
one there and the agent may keep its own notes in it. Unless the computer
settings turn it off, the sidecar reads it, through the computer (on a
Sprite, the Sprite reads it), when a message starts a run, and appends it to
the agent's instructions under `# Notes file (AGENTS.md)`. A file over 32 KB is
not read and the agent is told so; a symbolic link is not followed. A
computer that does not answer within 5 seconds (a Sprite waking) leaves the
conversation with the notes it last read.

- **`local`** is the directory `<agent folder>/<conversation id>` under the
  agent's working directory on this machine (`storage/agent/computers/bot-<id>`:
  the folder's name predates the rename and is kept), offered only with
  `AGENT_EXECUTION_MODE=trusted-local-single-tenant`. Unset (`none`) offers no
  local computer: the production default, failing closed. It is **not
  isolation**: one sidecar serves every agent, and a shell can read other agents'
  files, the store, its lock and the sidecar's configuration. Use it only
  where every user is the same trusted operator, such as one developer's
  machine. Any other mode makes the sidecar not ready.
- **`sprites`** is a microVM on a Sprites platform (`SPRITES_URL`),
  one per conversation, named `<prefix>-c<conversation id>` where the prefix is the
  agent's computer name, `<PI_DURABLE__SPRITE_PREFIX>-<environment>-b<agent id>` (the `b<number>` is an
  opaque identifier of a live Sprite; it was the bot's id before the rename). Offered only with
  `SPRITES_TOKEN` and `SPRITES_IMAGE`. The image is `Dockerfile.agent`: the
  pi-env daemon, the relay (`agent/sprite-relay.mjs`), the spawner
  (`agent/guest/spawner.mjs`) and the screen, started and watched by
  `agent/guest/entrypoint.sh`; no app code or secrets. The
  screen is a browser desktop stack: Xvfb `:99`, openbox, Chromium
  with its profile in `/home/browser/.config/chromium` (kept across
  sleeps, sandbox on, `--disable-gpu --disable-gpu-shader-disk-cache`) and
  its DevTools on `127.0.0.1:9222` under a token (below), x11vnc on `127.0.0.1:5900` (no password; never
  reachable from outside the guest), websockify on `127.0.0.1:6080`, and
  a desktop control server (`agent/guest/server.js`, vendored
  verbatim, control-only) on `127.0.0.1:8090` with a bearer made at each
  boot into `/run/desk/token`. Only the relay listens beyond the guest's
  loopback. **Who runs what (#58).** The image sets no `USER`: the
  entrypoint starts as root, refuses to go on otherwise, starts each process
  as its own user with `su-exec` and a fixed environment (`env -i`, nothing of
  its own), and then only watches them. It reads nothing the agent writes.
  The relay runs as `relay`, holding the relay's secret and the desktop's
  bearer; the desktop control server as `desk`, the bearer's file in
  `/run/desk` (0700, the file 0600, both `desk`'s). Chromium and what drives
  it run as `browser` (#60, below). Everything else runs as
  `agent`: Xvfb, openbox, x11vnc, websockify, and the spawner, which
  listens on `/run/spawn/agent.sock` (a directory only `agent` and `relay` may
  enter) and starts the pi-env daemon (so the agent's shell) and command
  connectors with a fixed environment. `pi-env serve` takes its token only
  as an argument (`--token <hex>`; pi-env 1.6.0 reads no environment variable
  or file for it), and any user on the guest can read a process's arguments.
  So the spawner starts the daemon with a token of its own and passes its
  first line on as `PI-ENV <the sidecar's token>`: the token the sidecar dials
  with is in no process's arguments (#63). The relay starts nothing itself: for
  `AGENT-RELAY` and `AGENT-COMMAND` it checks the secret and passes the
  connection, without it, to the spawner. So nothing that reads the agent's
  input runs as root, and the agent's user can read neither secret: not from
  a file, its environment or another user's `/proc/<pid>/environ`. The relay
  and the spawner exit if started as root. The desktop tool no longer runs
  anything on the computer: the sidecar sends each action through the relay
  (`AGENT-DESK <secret>`, then the action's JSON line), which posts it to the
  control server with the bearer and answers with the server's reply.
  **The browser's own user (#60).** A debugging port on loopback answers
  every user on the computer, so while Chromium's was open to `agent`, code
  the agent ran could read any field a filler had just filled. Chromium now
  runs as `browser`, started by `agent/guest/cdp.mjs` with
  `--remote-debugging-pipe`, so Chromium itself listens on no port.
  `cdp.mjs` serves DevTools on `127.0.0.1:9222` only under a path holding a
  token made at each boot (`/run/browser/cdp-token`, 0600 in a 0700
  directory, both `browser`'s); anything else gets 404. It multiplexes its
  clients over the pipe (a page's socket is a flattened session on that
  page) and holds the port while it starts Chromium again, so nothing else
  can take the port and be sent a filled page. `visit.mjs`, `fill.mjs`,
  `pay.mjs`, `answer.mjs` and `upload.mjs` run as `browser` too: the sidecar sends each
  through the relay (`AGENT-BROWSER <secret>`, then the command's JSON line),
  which answers `AGENT-BROWSER` and passes it to a second spawner, run as
  `browser` on `/run/browser-spawn/browser.sock` (only `relay` may reach
  it), which runs only `node` with one of those five scripts, passes on
  only `AGENT_*` variables, and gives each the token's address as
  `AGENT_CDP` once it has seen, in `/proc/net/tcp`, that its own user holds
  the port. So a sign-in or card goes from the sidecar to the filler through
  no process of the agent's, and the agent's user can read neither the
  token nor a filled value over the port: `bin/check-computer-image` has a
  command run as `agent` scan every process's environment and arguments for
  the password while `fill.mjs` fills it, and then ask the port for every
  password field's value; both found it before this change. Chromium's
  profile and cookies are in `/home/browser` (0700), out of the agent's
  reach, and so is `~/.visit-tab`. Its downloads go to the one folder it
  shares with the agent, below ("Files between the browser and the agent"). One difference from Chromium's
  own port: `/json/list` is not ordered by last use, which the pipe does not
  give, so `visit.mjs` takes the visible page with the keyboard's focus as
  the person's front page. **Not covered:** the screen itself. Xvfb,
  x11vnc and websockify still run as `agent`, as the desktop tool and "Open
  screen" need, so code the agent runs can see the screen and type into it,
  as a person at the screen can. A filled password shows as dots, as do the
  card's number and security code (`pay.mjs` masks them); the username, the
  name on the card and the postal code show as typed. Driving the browser
  by hand (opening its developer tools from the keyboard, say) could still
  show a filled value; that has not been tried, and Chromium's policy that
  turns developer tools off also turns off the pipe. A Sprite made before
  this keeps its old image: its fillers run as `agent` as before (the relay
  closes `AGENT-BROWSER` unanswered and the sidecar goes the old way), until
  it is remade.
  `bin/check-computer-image` builds the image, runs it and checks all of this
  as built, as `agent`, along with the screen, commands, `visit.mjs` and
  `fill.mjs`; `bin/ci` runs it where Docker is, and publish runs it on the
  image it pushes. Whether the Sprites platform runs the entrypoint as root
  (an image with no `USER`) has not been checked against the platform; if it
  does not, the entrypoint exits and the Sprite does not start, rather than
  run with every process as one user. **What a deploy changes on a Sprite:** the image, and with it
  everything under `/opt/agent/` (the relay, the entrypoint, the spawner,
  `cdp.mjs`, `visit.mjs`, `fill.mjs`, `pay.mjs`, `answer.mjs`, `upload.mjs`, `pdf-text.mjs`) and Chromium's policy, is chosen only when
  the Sprite is created, so an existing Sprite keeps the copies it was made
  with until it is remade, which loses its home folder. A deploy changes only
  the sidecar's side: `agent/*.mjs`, and scripts the sidecar sends with each
  call (`answer.mjs`). A change to a guest script is therefore a change for
  new Sprites, and its sidecar half must still work with the old copies: on a
  Sprite made before `AGENT-DESK`, whose relay closes that connection
  unanswered or reset, the desktop tool runs its old `/opt/agent/desk.mjs` as before,
  and there everything still runs as `agent`, the bearer and the relay's
  secret within its reach, until the Sprite is remade. There, too, typed text
  is briefly in `desk.mjs`'s and `xdotool`'s arguments; as everything runs as
  `agent`, that shows it to no one its environment would not. A new image
  types it from `xdotool`'s stdin, and `bin/check-computer-image` watches
  every process's arguments while it types. `agent/sprites-bridge.mjs` looks the Sprite up,
  creates it if missing (at the agent's size, by default 2 vCPU, 2 GiB, 8 GiB
  disk: `docs/computers.md`, "A Sprite's size"; asleep after an hour
  idle, never expiring: `idle_destroy_after: '0'`), starts it if stopped or
  cold, waits up to 120 seconds for its entrypoint, then connects to its
  private address. The platform's cold storage moves a disk asleep for 14 days
  to slower storage and brings it back on wake, through the same start; the screen's
  page asks the sidecar first (`GET /v1/conversations/:id/computer`, a lookup
  that wakes nothing) and says "Waking up, this can take a minute" for a cold
  one. At the platform's awake cap for the token's scope, create or start answers 429
  `scope_capacity_exceeded`; the run stops as `computers_busy` ("Too many
  computers are awake; try again shortly"). Nothing is queued and no other
  conversation is put to sleep. Deleting an agent deletes its Sprites, one per
  conversation, with their disks: after the agent is gone, `ComputerRemovalJob`
  sends `DELETE /v1/conversations/:id/computer` for each, and the bridge deletes
  the Sprite (one already gone is fine). It retries while the sidecar is down.
  Apart from an operator's remake (below), this is the only way a Sprite goes. The relay starts the daemon only for a connection
  that opens with a secret derived from the token and given to the Sprite at
  creation; pi-env's `RemoteExecutionEnv` drives it. The connection opens
  when a conversation with a Sprite runs (Pi builds the environment for each model
  request and tool call); while open the bridge looks the Sprite up each
  minute, since direct traffic is not activity to the platform, and it exits
  after `SPRITES_IDLE_MS` (60 s) without a request. Nothing of the sidecar's
  environment reaches the Sprite. Nothing here limits where a Sprite may
  reach on the internet: the app sets no egress list. Tested against a loopback stand-in of the API
  (`agent/test/sprites-stand-in.mjs`) and with the built image as a plain
  container; not yet against the platform itself. Rotating `SPRITES_TOKEN`
  changes the relay secret, which a Sprite keeps from its creation: recreate
  its Sprites (their files go with them) or keep the token.

**Holding a computer.** The bridge creates a Sprite that is missing, so an
operator who deletes one to rebuild it first holds the agent's computer, or
its next message, notes file, desktop action or command connector makes a
fresh one in its place. On the install, with the agent's id:

    bin/rails runner 'Agent.find(ID).computer.hold!'
    bin/rails runner 'puts Agent.find(ID).computer.size.to_param'   # e.g. 4,8192,16384
    node agent/sprites-bridge.mjs <sprite> remake --size 4,8192,16384
    bin/rails runner 'Agent.find(ID).computer.release!'

The remake runs where the sidecar runs, with its `SPRITES_*` settings. It
deletes the Sprite and its disk, then makes it again. With `--size` (CPUs,
memory and disk in MiB), at that size: this is how a conversation's existing
computer takes a size set since it was made. Without it, with the old one's
memory when the platform reports it (`mem_mib`), else 2 GiB, so a Sprite
whose memory was raised by hand on the host keeps it. Deleting it by hand
instead and letting the next use make it gives the agent's size.

`computers.held_at` marks the hold. If a message arrives through a channel
(Concourse, email, Campfire, and other `Conversation#receive` callers) during
the hold, Rails saves its encrypted submission and queues
`ConversationDeliveryJob` instead of sending it to the sidecar. The job
passes only the submission's record reference and retries with increasing
delays: ten attempts in all, with no worker kept waiting. Once released, it
sends the same words under the same request ID, without duplicating the
message. Nothing stops the thread or sends an error notice while it waits.
Only if all attempts meet the hold does the thread show and notify the usual
“this computer is being rebuilt; try again shortly” failure.

The web composer and the separate paused-agent queue are unchanged. When
a held definition does reach the sidecar, it neither wakes nor makes the
computer, and the run stops as `computer_held`. Command connectors still
answer `503 computer_held`; Rails shows why on the screen page and refuses
its websocket before asking the sidecar. A hold set after Rails has delivered
a turn is not picked up by the retry job: the sidecar may still have the old
definition. Hold before deleting and wait for the agent to finish. Releasing
restores the definition; the next use makes the Sprite again.

**The screen.** A conversation whose computer is a Sprite that is on has an "Open
screen" button. Its page (`Conversations::ScreensController`) runs noVNC
(vendored, pinned in the importmap) against a websocket to the same address.
Rails checks the signed-in person (their session, and that the conversation is theirs), the
computer and the Origin (`APP__URL`), then relays the websocket
(`async-websocket`) to the sidecar's `GET /v1/conversations/:id/screen`
over its socket. The sidecar wakes the Sprite, dials the relay with
`AGENT-SCREEN <secret>`, forwards the request to websockify and pipes
bytes; while it is open, the bridge looks the Sprite up each minute, which
keeps it awake. You watch and type while the agent works; there is no
takeover mode.

**Sharing the screen once.** Someone not signed in here sometimes has to
type on it: a code a site sends to their phone, say. "Share this screen" on
the screen page makes a one-time link (`ScreenPass`) and shows it that once;
only its token's digest is kept. The first device to open it gets a key of
its own in an encrypted cookie and may reload; any other is refused. It lasts
ten minutes, and ends sooner when its maker presses "End it" or the visitor
"Done". Its page shows the same screen, bar and noVNC, and nothing else of
the app; the websocket at its address needs the device's key and the site's
Origin, and the relay (`ScreenRelay`) checks the link every few seconds and
cuts the screen when it ends. What the visitor types goes to the screen and
is neither kept nor logged here; they see the whole screen, so leave only
what they need open. The link's token is in its address, so it is in the
request log until it is opened; after that it is worth nothing without the
device's key. Logins made in the screen's Chromium stay in its profile.
The launcher sets the startup preference to open the New Tab page instead
of restoring the old tabs. A brand-new profile still starts on `about:blank`.
The agent uses the same browser: `visit_website` shows the page as a tab in
the screen's window over CDP (`agent/guest/visit.mjs`, the tab's id in
`~/.visit-tab`) and brings it to the front (`Target.activateTarget`), so the
person sees what the agent sees, ctrl+Tab reaches every page, and the page
filled is the one in front. Chromium paints only the tab in front of a window,
and a screenshot of any other never answers, so the visit's tab is in front
when it is read. A visit navigates only a tab of its own that is on the site
asked for (one host a subdomain of the other, `www.` included) or still
blank; another site gets a new tab (`Target.createTarget`, which Chromium puts
in the window last in front). A site may treat its tab as a session and lock
the person out when it is taken away ("another instance open"), so a tab
the person or a site opened is never navigated or closed. Its own tabs are
those whose history starts with `about:blank#visit_website`, which it opens
each with, and the one `~/.visit-tab` names; the history survives a browser
restart, where ids do not. Until 16 November each visit used one tab in a
window of its own, opened behind the person's so their tab kept the top and
the keyboard; agent b10 then filled a page in that hidden window while the
person's screen kept an old `about:blank` window in front, which ctrl+Tab
could not leave. A window holding only the visit's own tabs, other than the
person's, is now closed, so no page is left in a hidden window. A tab of its
own that no longer answers (its page crashed or hangs) is closed and a new one
opened. The check is a script run in the page within a few seconds
(`Runtime.evaluate`): a renderer wedged after memory kills still lists its
tab, and the browser still answers for it, while the page runs nothing. A new
tab that does not answer either fails the visit at once. To choose its tab a
visit asks every tab at once, all by one three-second deadline: asked one by
one, 34 tabs whose background pages did not answer took its whole 40 seconds.
The choosing has its own 10 seconds ("its tabs did not answer within 10 s"),
and the page its 40 after that. Headless Chromium loads the page only when the screen's browser cannot be
reached; one that answers but cannot give the visit a tab fails the visit, since
a headless page would be reported while the screen kept the page before it. A
screen visit that fails or runs out of time is an error, never a
headless page the screen does not show. A visit is reported only when the tab
then shows the page asked for (#73): the same address (trailing slash, default
port and fragment aside), the same site (one host a subdomain of the other,
`www.` included), or a page the navigation itself committed
(`Page.frameNavigated`), which is where a redirect to another site lands.
Otherwise it fails naming both addresses. A tab that answered but never left
the earlier page used to be reported as the new one: a late load event from
that page ended the wait. Only a load after the new page commits counts now.
Existing Sprites keep their old `visit.mjs` until remade. The error says why: `visit.mjs`'s exit
code, or the time limit it ran out, and its last line of stderr, cut to 200
characters; that line already reads "The browser could not open …", so only
its reason is kept (that script prints no typed value; `fill.mjs` runs elsewhere and
its stderr is not passed on). And
the `desktop` tool (screenshot, click, type, key, scroll, drag, wait) goes
through the relay (`AGENT-DESK`) to the control server's `/action`. Helpers
never get `desktop` or `browser_upload` (below). A saved sign-in is filled into the `visit_website` tab,
never a tab of the person's, by `agent/guest/fill.mjs` (`docs/passwords.md`),
and a one-time card by `agent/guest/pay.mjs` (`docs/payments.md`). On a
Sprite made from this image, what these fillers type is hidden from the
model's view and from code running as the agent's user, which can reach
neither the fillers nor the browser's DevTools; it can still see and type
into the screen, where a password and a card number show as dots (above,
"The browser's own user"). On a Sprite made before it, they run as `agent`
and a program the agent runs can read a filled field's value (#60).

**Popups.** The image's Chromium policy
(`/etc/chromium/policies/managed/agent.json`, from
`agent/guest/chromium-policy.json`) allows every page's popups
(`DefaultPopupsSetting`): a lender's document viewer opens its document with
`window.open` after fetching it, when the click's activation has lapsed, and
Chromium blocked it. Chromium has no policy for popups from a gesture alone.
A popup opens as a tab in front of its window, which the agent sees, reads
and closes with `desktop` (ctrl+w); one asking for a size opens as a small
window on top. `bin/check-computer-image` clicks one opening at once and one
six seconds later.

**Nothing saved, nothing to reveal.** After a sign-in was filled and sent,
Chromium offered "Save password?" with the username, the password in dots
and an eye that shows it; Save would have kept it in the password manager,
which shows it too. The agent drives this screen, so one click would show it
a password it must never see. The same policy turns off Chromium's password
manager (`PasswordManagerEnabled`), its check of a sent password against
known leaks (`PasswordLeakDetectionEnabled`, which sends it, hashed, to
Google and warns over the page), and Autofill for cards and addresses, which
offered "Save card?" after a one-time card was sent. Chromium 156 calls
`AutofillCreditCardEnabled` and `AutofillAddressEnabled` deprecated in favour
of `AutofillSettings`, yet with `AutofillSettings` alone it still offered
"Save card?", so all three are set; `chrome://policy` shows the two old ones
as "Deprecated", still applied. `pay.mjs` and `fill.mjs` set a field's value
themselves and never use Autofill, so both still fill.

Turning saving off keeps what a profile saved before, and on Linux the
password page shows a saved password with no other sign-in (the computer has
no keyring). So `URLBlocklist` blocks `chrome://password-manager` and all of
`chrome://settings`, every page under each: the list matches a path's start,
and `/*` is not a wildcard there (it blocks nothing). All of Settings, not
its pages of saved passwords, cards and addresses alone, because a page inside
Settings is reached by a click that changes its address without opening a
page, which a blocklist of those pages lets through. `chrome://policy` stays
open, to reload a policy. A person's own settings (theme, search engine) are
out of reach on this screen too.

`bin/check-computer-image` reads each policy in `chrome://policy` (its value,
Mandatory, and OK, the two old ones OK or Deprecated) and checks that page
still opens; sends a filled sign-in and a filled card and checks that no
bubble, key or card icon appears; opens Settings, the password manager and
their pages of saved things in a tab behind the person's, expecting
Chromium's "This page is blocked"; and takes the same way in through
Chromium's menu, as the agent could on the screen: the three dots, then
Settings, then each page under "Passwords and autofill", found by reading the
menu with tesseract. A page that is not blocked is named and closed, never
read or shot.

**Files between the browser and the agent.** The browser's user cannot read
the agent's files, nor the agent the browser's (#60). They share one folder,
`/home/agent/browser-files`: the agent's, group `browser`, set-group-ID
(2770), made or put right at each boot by the entrypoint, as root, through a
handle on the folder itself that follows no link (the agent could leave one
there). Chromium downloads into it without asking (`DownloadDirectory`,
`PromptForDownloadLocation` false). `browser_upload(field, path)`
(`agent/browser-upload.mjs`) puts a file from the agent's home folder into a
file field of the tab `visit_website` last opened (`~/.visit-tab`), never a
tab of the person's, even one in front (#115), as the fillers do: the agent's
own command copies it into
`~/browser-files/.uploads/<id>/`, and `agent/guest/upload.mjs`, as `browser`
through the relay, takes a copy into its own `~/uploads` and sets the field
(`DOM.setFileInputFiles`), found by CSS selector or by its label's text. The
agent can write the shared folder, so `upload.mjs` takes only a plain file
really in it (opened without following a link, its real path read back from
the open file, one name only), and the page gets the browser's own copy,
which the agent cannot swap afterwards for a link to the browser's cookies.
It is the screen's, beside `desktop`: only an agent on a Sprite has it, never
its helpers. Like the sidecar's other tools it is not one of the definition's
tools, yet the model sees it, so it counts toward `Agent::TOOL_LIMIT`
(`agent/own-tools.json`). A Sprite made
before it has no shared folder and no `upload.mjs`; the tool says it must be
made again. Only the page's top frame is searched for the field.

**Command connectors.** A person's `command` MCP server runs on each
conversation's computer (`docs/connectors.md`). Rails posts each JSON-RPC message
to the sidecar's `POST /v1/conversations/:id/connectors/:name/rpc`; the
sidecar (`agent/command-connectors.mjs`) keeps one process per conversation and
connector, in its local folder or, through a bridge dialling the relay with
`AGENT-COMMAND <secret>`, in its Sprite as `agent`. While one runs, the
bridge keeps the Sprite awake; after 10 minutes without a call the process
stops and the Sprite may sleep. The image has `nodejs` and `npm` for `npx`
servers; no Python or `uv`.

Settings (`.env.example`): `PI_DURABLE__SIDECAR_URL`, and two distinct tokens,
`PI_DURABLE__SIDECAR_TOKEN` (Rails to sidecar) and `PI_DURABLE__RAILS_TOKEN`
(sidecar to Rails). Blank, short or equal tokens refuse every call. Generate
each with `bin/rails secret`.

An agent may choose only a model on `config/pi_durable.yml`'s list that the
sidecar can run: one of pi-ai's models for a provider it has a key or
subscription for (`GET /v1/models`). The agent's settings offer just those, each
with the thinking levels pi-ai says it supports (`ModelCatalog`, cached ten
minutes; every level when the sidecar can't answer, since the sidecar runs a
model at its nearest supported level). ChatGPT's models are offered only once
someone has signed in to its subscription at `/subscriptions`; signing in or
out changes the menus at once. An agent already on one keeps it while nobody
is signed in, and its next run stops, saying it isn't signed in. An agent on a
model later taken off the list keeps it, and the sidecar still runs it; it
just can't be chosen again. The sidecar never falls back to another
model, and is not ready (`GET /up` answers 503) with no provider at all. `AGENT_MODEL_MODE=local` offers only `local/stand-in`, a free
scripted stand-in (`agent/local-model.mjs`) that understands `remember key:
text`, `forget key`, `notes`, `ask` and `time`. Development
uses it by default (`Procfile.dev` sets `AGENT_MODEL_MODE=local`); tests use
scripted models only.

## Deploying

Each destination (`config/deploy.example.yml`, and an install's own)
has an `agent` role beside `web` and `job`: same host, same image, same
`storage` volume, `proxy: false`, command `bin/agent-container`.

- **Image.** The `Dockerfile` copies the `node` binary from the pinned
  `node:24.22.2-bookworm-slim` image and runs `npm ci --ignore-scripts
  --omit=dev` in `agent/` during the build. npm stays in the build stage. The
  tag is pinned; its digest is not, so pin it before the first deploy.
- **Private reachability.** The sidecar listens on its own container's
  loopback only. `bin/agent-container` forwards a Unix socket on the shared
  volume (`AGENT_SOCKET`, `/rails/storage/agent/sidecar.sock`, mode 0600) to
  it, and web and job reach it at `PI_DURABLE__SIDECAR_URL=unix:///rails/storage/agent/sidecar.sock`.
  Nothing listens on a network interface and no port is published. Kamal
  still attaches the container to its shared `kamal` network; the sidecar
  uses it only to call Rails back at `AGENT_RAILS_URL` (the web role's
  network alias). Those nine callback routes (`/agent/accesses`,
  `/agent/invocations`, `/agent/frames`, `/agent/syncs`, `/agent/sign_ins`,
  `/agent/cards`, `/agent/files`, `/agent/uploads`, `/agent/helpers`)
  skip host authorization (`config/initializers/pi_durable_callbacks.rb`), as
  do only `/up` and Campfire's webhook besides; they refuse any request
  without `RAILS_TOKEN`.
- **Tokens.** `.kamal/secrets.<destination>` resolves
  `PI_DURABLE__SIDECAR_TOKEN`, `PI_DURABLE__RAILS_TOKEN` and any provider key
  from their own Passbolt resources (placeholders until created; the
  pre-deploy hook refuses a blank one). Web and job get the two tokens; only
  the agent role gets a provider credential, and it never gets `RAILS_MASTER_KEY`.
- **Subscriptions.** The agent role reaches Claude through a
  Claude subscription, as Pi does after
  `/login anthropic` with the pi-anthropic-auth extension; and OpenAI's Codex
  models through a ChatGPT subscription, as Pi does after
  `/login openai-codex`. No deploy-time API key, and no fallback to one. The app owns its
  own grants: an admitted person signs in once to each at `/subscriptions`
  (Rails' owner console, behind sign-in), which calls the sidecar's
  `/v1/subscriptions/:provider` routes. ChatGPT's sign-in ends on
  `http://localhost:1455/…`, which does not load; the owner pastes that
  address into the console. The sidecar keeps each grant in its own file,
  `CLAUDE_SUBSCRIPTION_FILE` (`/rails/storage/agent/claude-subscription.json`)
  and `CHATGPT_SUBSCRIPTION_FILE` (`chatgpt-subscription.json` beside it),
  mode 0600, left out of `storage.tar`, encrypted with `SUBSCRIPTION_VAULT_KEY`
  for this install (`AGENT_APPLICATION`) and scope (`SUBSCRIPTION_VAULT_SCOPE`,
  unset meaning `DEPLOYMENT_ENVIRONMENT`)
  (`agent/subscription-credentials.mjs`, ported from an earlier
  implementation). A grant sealed for another name or scope stays on disk
  but can't be opened: /subscriptions says to sign in again, and an agent's
  turn stops with "its sign-in can't be opened". To rename the environment,
  first set `SUBSCRIPTION_VAULT_SCOPE` to the old name on the agent role,
  then rename `DEPLOYMENT_ENVIRONMENT`. A sign-in link is one-use and lasts ten minutes; each
  exchange or refresh is recorded before it is sent and never replayed, so an
  interrupted one means signing in again. Never copy another program's grant
  or key here. pi-ai adds Claude Code's identity for the token, and
  `agent/claude-subscription.mjs` adds the extension's billing block;
  `CLAUDE_CODE_VERSION` there follows pi-ai's, raised when Anthropic answers
  `claude_code_version_too_old`. ChatGPT's requests are pi-ai's `openai-codex`
  provider's, unchanged. `agent/test/claude-subscription.test.mjs` and
  `chatgpt-subscription.test.mjs` pin the requests pi-ai builds for each
  grant, so a pi-ai upgrade that changes them fails CI.
- **Lending a subscription (optional).** Two holders on one machine may
  share one subscription. Copying the grant into both would not work: each
  refresh rotates the refresh token, so they would sign each other out.
  Instead the one that signed in, the lender, keeps and refreshes the grant as
  ever and lends only its current access token; the other, the borrower,
  keeps that token at most five minutes (and never into the lender's refresh
  window, its last five), and holds no refresh token. Each provider has one
  route, `GET /v1/lend/<provider>`, on a Unix socket of the lender's own, mode
  0600, never on a network; the borrower presents
  `CLAUDE_SUBSCRIPTION_LENDING_SECRET` (32 characters or more), set the same on
  both. One socket may answer more than one route.

  - **Claude** (`/v1/lend/anthropic`). Another install lends its own grant:
    1. Make a host folder for the socket, owned by the containers' user
       (uid 1000): `install -d -o 1000 -g 1000 -m 700 /var/lib/claude-lending`.
    2. On both installs' `agent` role, mount it (`volumes:
       - /var/lib/claude-lending:/lending`) and add the secret to the role's
       secrets.
    3. The lender's role sets `CLAUDE_SUBSCRIPTION_LEND_SOCKET:
       /lending/claude.sock`; the borrower's sets
       `CLAUDE_SUBSCRIPTION_BORROW_SOCKET: /lending/claude.sock`. The borrower
       keeps `CLAUDE_SUBSCRIPTION_FILE`, which then holds only its pasted API key.
  - **ChatGPT** (`/v1/lend/openai-chatgpt`). The owner's own "Sign in with
    ChatGPT", which Pi keeps for its `openai` provider, lent by a small service of the owner's beside it that answers this route
    as an install answers Claude's: `{ access, expiresAt, lender }`, the
    access token only, refreshed through Pi's own locked credential store.
    No install lends it. The borrower sets `CHATGPT_SUBSCRIPTION_BORROW_SOCKET`
    and offers the `openai-chatgpt/…` models: pi-ai's `openai` models and
    Responses API at api.openai.com, sent as pi-ai sends its own ChatGPT
    sign-in (`agent/chatgpt-lending.mjs`). It never sets
    `CHATGPT_SUBSCRIPTION_FILE` as well (`chatgpt_credential_ambiguous`): one
    ChatGPT account per install. A token that is an OpenAI API key (`sk-`) is
    refused, never run as the subscription. Web search isn't offered on these
    models yet. **Lend a personal ChatGPT sign-in only to its owner's own
    install, never to another person's:** OpenAI's terms don't allow making
    an account available to anyone else, and every borrower draws on the same
    usage limits as the owner's own use.

  The borrower's /subscriptions says whose sign-in it uses (the lender's name)
  and offers no sign-in or sign-out: those happen at the lender. Its models
  are offered only while the loan works. With the lender signed out,
  deploying or down, they stop as if signed out, with no fallback to an API
  key, and come back on their own. A sidecar that is told to lend but has no
  grant of its own, or borrows itself, is not ready (`claude_lending_invalid`);
  a bad ChatGPT borrow setting is `chatgpt_lending_invalid`.
  `agent/test/subscription-lending.test.mjs` and `chatgpt-lending.test.mjs`
  hold all of this.
- **Claude routes (optional).** A borrower may borrow Claude from several
  lenders, each another account's subscription, instead of one:
  `PI_DURABLE__CLAUDE_ROUTES=main=/lending/main.sock,spare=/lending/spare.sock`,
  named routes in the install's order, first then fallbacks, all with the one
  lending secret and never with `CLAUDE_SUBSCRIPTION_BORROW_SOCKET`
  (`claude_routes_ambiguous`; a malformed list is `claude_routes_invalid`).
  Set it on both roles: the sidecar borrows through the sockets (`bin/agent`
  passes it as `CLAUDE_ROUTES`), Rails keeps only the names.
  A name is 1–32 characters: a lowercase ASCII letter first, then lowercase
  letters, digits, hyphens, `@` or `.`. Use a label safe to show in logs and
  settings; never put a secret in it.

  A Claude call goes to the first route not at its usage limit. Refused for
  the limit (HTTP 429), by the lender with 503 `subscription_unavailable`, or
  with the lender's socket absent or refusing the connection,
  it is asked on each next route in turn, each at most once, so the turn goes
  on with no reply lost; refused on the last route too, or with that lender
  unreachable, the run stops plainly (`rate_limited` or
  `credential_missing`). Any other error stops the run on the route it came
  from. Calls stay on the
  fallback until the first route's reset time, from the 429's
  `anthropic-ratelimit-unified-*` headers (a `rejected` window's own
  `-5h-reset` or `-7d-reset`, else `anthropic-ratelimit-unified-reset` when
  `anthropic-ratelimit-unified-status` is `rejected`; epoch seconds, read as
  the pi claude-account extension reads real responses), or, with none given,
  until a call tried on it again every 15 minutes succeeds; then they go back.
  These are the signals a person switching accounts by hand goes by; no usage
  endpoint is read, since the sockets lend none. A route only picks a socket:
  nothing signs in, refreshes or reads a lender's sign-in.

  Each switch is logged by route name (never a path or token), and
  `/subscriptions` shows each route's state: in use, in use as the fallback,
  limited (until when, if known) or standby. An agent may name its own route
  in its settings (`agents.claude_route`, sent as the definition's
  `claudeRoute` only when set); it then comes first, the install's others
  after. A route the sidecar has not got leaves the install's order; a helper
  goes by the route of the conversation it works for.
  An install with a sign-in of its own (`CLAUDE_SUBSCRIPTION_FILE`) may lend
  it (`CLAUDE_SUBSCRIPTION_LEND_SOCKET`) and route its own calls at once: the
  lend socket serves the install's own account, whatever its routes, and one
  of its routes may name that same socket, so its own account takes its turn
  in the order. That route uses the install's own grant directly, never
  through its own socket. Lending and the install's own calls share that one
  grant and its one refresh: many asking at once near its end cause a single
  refresh, made by the install as ever; a route never signs in or refreshes.
  If the refresh fails, borrowers get 503 `subscription_unavailable` and the
  install's own calls move to the next route. Without routes, lending is as
  before. All the routes and the lend socket use the one lending secret. While routes
  are set, `/subscriptions` shows the routes, not the install's own sign-in,
  so that sign-in is made, or made again, with the routes unset. Lending with
  no sign-in of its own is still `claude_lending_invalid`.
  `agent/test/claude-routes.test.mjs` holds this with made-up lenders on real
  sockets.
- **Claude API key (optional).** Beside the Claude subscription, an admitted
  person may paste an Anthropic API key at `/subscriptions`. It serves only
  the `anthropic-api/…` models, billed per token; `anthropic/…` stays the
  subscription, and neither is a fallback for the other. Rails passes the key
  to the sidecar's `/v1/subscriptions/anthropic-api/key` and keeps nothing
  (`api_key` is a filtered parameter). The sidecar
  (`agent/claude-api-key.mjs`) refuses a subscription token or a malformed
  key, checks the rest with Anthropic's free model list, and seals a good one
  with `SUBSCRIPTION_VAULT_KEY` in `CLAUDE_SUBSCRIPTION_FILE` (else
  `CHATGPT_SUBSCRIPTION_FILE`) under its own namespace, so the grants there
  open as before. Only its last four characters are ever shown. No key does
  not make the sidecar unready; a run on an `anthropic-api` model without one
  stops as `credential_missing`. `agent/test/claude-api-key.test.mjs` pins
  that pi-ai sends it as `x-api-key` with none of Claude Code's identity.
- **Replacement without overlap.** Kamal starts the new container before it
  stops the old one. The new sidecar finds the store owned (`GET /up`
  answers 503 `store_already_owned`); `bin/agent-container` stops it, retries
  every two seconds, and serves only once it owns the store, so two
  sidecars never write one store. It never deletes the lock. Any other
  not-ready reason, or no ownership within `AGENT_OWNER_WAIT` seconds
  (default 120), exits non-zero. Requests in that window get 503.
- **One host.** The lock is a single-host kernel lock. Never give the role a
  second host or move the volume to shared storage.

Nothing here has been deployed or built into an image by the template's
own tests; the Rails tests read the generated deploy files and Dockerfile and
run `bin/agent-container` against a stand-in sidecar.

## Interfaces

The wire between Rails and the sidecar, with what each message promises, is
`docs/design/CONTRACT.md`; it is the only copy.

The private forge file seam is inert without a live forge tool call. Both
`FORGE__AGENT_ID` and `FORGE__WORKSPACE_ID` must name the same admitted
agent and workspace on the Rails job and web roles. It uses the live call's
own Sprite, never a named computer, a helper's computer, SSH or the sidecar
disk. The Sprite image must contain the forge file helper. Its Linux
filesystem must support anonymous temporary files and atomic hard links.

Rails keeps each transfer under `storage/forge-files` on its existing
private volume only while the job owns it. This is not attachment storage,
and no volume is mounted on the Sprite. A killed Rails process can leave
an orphan; when no transfer is running, remove abandoned transfer
directories older than the job run limit. An interrupted Sprite write
leaves no named partial. Published files are read-only and never replaced
by the seam. The guest user still owns the directory and can delete or
replace a file outside the seam; do not treat a returned path as immutable.

Browser resources, with CSRF (`config/routes.rb` is the full list):
`agents` (new, create, show, edit, update) and their settings beneath
(`computer`, `concourse_agent`, `campfire_bot`, `prompts`, `skills`,
`routines`, `permissions`, `pause`); `conversations` (index, show) with
`messages`, `submissions`, `queued_messages`, `held_messages`, `cancellations`, `compactions`, `export`,
`archive`, `screen` (show, and its websocket), `connectors`, and
`invocations/:id/approval`, `.../answer` and `.../sign_in`. A conversation page subscribes to its Turbo stream: messages
append as they are pulled, the live tail and status are replaced by frames,
and a tool call's card is replaced as its ledger row changes. Closing the page
never cancels a run.


## Retained state

The sidecar's store is `AGENT_STORE` (default `storage/agent/durable.sqlite`,
plus its `-wal`/`-shm` files and a `.owner.sqlite` lock beside it). It must
live on a persistent volume, never in the image or a disposable layer.
Ownership is a kernel-held lock on the lock database, not a lease: a second
sidecar on the same store refuses to start, and the lock is released when the
owner exits or crashes. It is a single-host lock. Never share a store between
replicas or hosts, and never delete the lock file to "unstick" a start.

To replace the sidecar (deploy, move): stop the old process and confirm it
has exited before starting the new one on the same store. Unfinished work
resumes at boot without waiting for a browser request. Frames and syncs
resume only for conversations Rails made: a helper's own conversation has no
row in Rails, so it never streams, at boot or otherwise. A frame or sync Rails
answers 404 (no such conversation) is not retried: the sidecar logs one line
with the conversation's id and stops streaming it. Other failures are
handled as before.

## Backup and restore

`ops/backup/<app>-backup.sh` includes the store. It stops the agent
container, snapshots the store with `bin/agent-store` inside the web container
(same volume, same lock), snapshots the Rails databases in the same window, so
both come from one point in time, and starts the agent container again on
every path out, success or failure. The staged set gains
`agent-durable.sqlite` and its `agent-durable.sqlite.manifest.json`; the live
store, its lock and the socket are kept out of `storage.tar`. The sidecar is
down for the few seconds the snapshots take. No running agent container, or
one that will not stop, fails the backup. `ops/backup/<app>-restore.sh`
checks the snapshot against its manifest's SHA-256 and with `integrity_check`.

By hand (development, or a host without the script), `bin/agent-store` wraps
`agent/store.mjs`. It takes the same ownership lock as the sidecar, so it
refuses while `bin/agent` runs: stop the sidecar, confirm it exited, snapshot,
start it again.

    bin/agent-store snapshot /path/to/stage/agent-durable.sqlite
    bin/agent-store restore /path/to/stage/agent-durable.sqlite storage/agent/restored.sqlite

A snapshot is a consistent `VACUUM INTO` copy that passes `PRAGMA
integrity_check`, published by rename; its `<snapshot>.manifest.json` (with
the SHA-256) is written last, and a snapshot without one is incomplete.
Restore writes only to a fresh path and checks the digest and integrity
before the store appears. Point `AGENT_STORE` at the restored file and start
one sidecar: pending questions and unfinished tasks come back with it.

Restore the Rails database from the same point in time. If they disagree,
Rails refuses to map a sidecar conversation it already knows under another
request (409) rather than guess. The invocation ledger in Rails is what stops
a replayed tool call from running twice; a Rails database older than the
store can let a committed call run again. An outside call (an email, a text,
a post) cut off before its result was saved, by a worker killed mid-call, is
never made again: five minutes after its job began it (`Invocation::RUN_LIMIT`)
it fails, saying whether it happened is unknown, and the agent checks before
trying again. One whose job has not begun it has not happened, so it waits for
a busy job role, is queued again if Solid Queue no longer holds its job, and
only after half an hour (`Invocation::QUEUE_LIMIT`) ends, saying it was never
made. A call claimed by code from before `claimed_at` keeps the five minutes.
A Concourse send is the exception: its message is named by the call, and
recorded (`Dispatch`) before Concourse is asked, so run again it sends
nothing and asks Concourse's receipt for that message instead
(`docs/design.md`, "When Concourse is slow to answer").
The `messages` copy is rebuilt from
the store with `Conversation#resync!`.

To put a snapshot live: stop the web, job and agent roles, restore the Rails
databases and `bin/agent-store restore` the store to a fresh path from the
same set, point `AGENT_STORE` at it (or move it to
`storage/agent/durable.sqlite` while nothing runs), and boot all three.

Off-host copies have the same gap as the rest of the app (S11): a host whose
borgmatic cannot reach another host's stage has no generic pull yet, so the
agent snapshot, like the databases, stays on that host.

## Limits

- A local computer's directory is not a sandbox (above). A Sprite is
  a microVM, isolated from the app's files, but not yet tried on the platform.
- A local computer's files live under `storage/agent/computers/` and travel
  in `storage.tar`; a Sprite's files stay on the Sprite, in no backup of this
  app.
- Shells start with a minimal environment, but nothing here is an operating
  system egress firewall.
- The deployment above is configuration only. The template's tests never
  build the image or deploy it; the first real deploy is a deliberate step.
  An install reaches Claude and ChatGPT through subscriptions (above), not
  deploy-time keys; an Anthropic API key pasted in the console is optional.
