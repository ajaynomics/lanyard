# Phone

An agent can have a phone number of its own and send texts from it with
`send_text`. The number is one of the install's voip.ms numbers (a "DID").
Texts to it, and its voicemail, reach the agent as email, through voip.ms's
own forwarding. Nothing comes in by webhook. voip.ms is the one provider,
with no layer for others. Calls and buying numbers from the app are not built.

## Voice pilot

Off by default. Bind one agent and project in `.env.example`’s `VOICE__`
settings. Any caller reaches the agent: the gateway checks which number was
called. The dedicated `live.transport.incoming`
endpoint has no project ID in its payload: set `VOICE__WEBHOOK_PROJECT_ID` to the
project that issued its signing key; it must match `VOICE__PROJECT_ID`.
Vault entry: **OpenAI | Voice pilot webhook secret** (`VOICE__WEBHOOK_SECRET`). The
gateway's own entries,
**VoIP.ms | Voice gateway sub-account** and **Voice gateway | SIP login and TLS**, stay on
the gateway; the app never reads them. Inject them through Kamal
destination secrets (`docs/deployments.md`).
SIP numbers do not prove identity.

Each verified offer goes to a job, off the webhook, which OpenAI wants answered
within seconds. The job accepts a newly recorded offer once, through OpenAI's
Live API (`POST /v1/live/sessions/{id}/accept`), as the bound agent, on
`VOICE__MODEL` (default `gpt-live-1.1`). The call gets a short prompt
(`Agent::VoicePrompt`): the agent's name, title and owner, that it is a brief
phone call, what it can do, and its owner's instructions, cut to 4,000 characters.
A call from a number on file in the workspace also hears the agent's own
thread, for context: its newest summary, cut to 1,000 characters, and up to ten
messages since, newest kept, within 1,500 in all. No other workspace's thread
is read.

**Which calls can hear the thread** (`Agent::VoiceCall::Reach`) is decided
when the offer arrives. The number in the one SIP `From` header must match a
number on a current membership in the bound agent's workspace, whether it
belongs to the owner or another member. Both are compared as ten North
American digits. A missing, ambiguous, invalid or unmatched number gets
stranger reach and hears no thread. Only the reach is stored (`owner` for a
match, `stranger` otherwise), never the number. Caller ID can be faked, so
even matched calls are read-only.
It claims the offer before asking, so a replay or a second run asks nothing
more. A signed offer for no agent, or one that
conflicts with a recorded one is declined at once with SIP 603 and not kept.
With voice off or no `VOICE__API_KEY` (the install's OpenAI API key, from its
vault), nothing is sent. An accept that times out or gets a server
error is recorded `unknown` and never retried; a refusal is `failed`. Errors
name the HTTP status only.

### Ask the agent during a call

A call from a matched number gets `ask_agent` through `VOICE__BACKEND_MODEL`; a
stranger gets no tool. On the same sideband as the transcript, it asks the
agent in its own thread without interrupting busy work. It speaks only that
question's answer, waits at most twenty seconds, and never submits it twice.

Both the question and transcript can use only the enabled built-in reads for
time, calendars, notes and documents. No connector or computer tools, writes,
outward actions or approval cards, even with approve-everything. Ask in writing
to take an action.

Before rolling back to a sidecar that predates the phone boundary, stop new
phone submissions and drain queued or in-flight phone work. The older
sidecar rejects new phone requests, but cannot protect work already stored.

### After a call

Once an accepted call ends, what was said reaches the bound agent's own
thread, and the agent is asked to reply there with a summary in three lines.
A call placed with `place_call` (below) makes no voice-call row and is not
listened to.

- **Where it comes from.** OpenAI sends no webhook when a call ends, and its
  API has no transcript to fetch afterwards (only a stored recording's audio,
  which this app does not ask for): the only text of a call is the transcript
  fragments its "sideband" WebSocket sends while it runs (OpenAI's Telephony
  and SIP guide, "Attach your backend", and Managing GPT-Live sessions,
  "Transcript deltas"). They come without any transcription setting in the
  accept. So the job that accepts a call attaches at once to
  `wss://api.openai.com/v1/live/sessions/{id}/attach` with the same key and
  an HTTP/1.1 WebSocket upgrade, not HTTP/2's extended CONNECT. The sideband
  replays only the 3 seconds before it attaches and listens until
  `session.closed` (`DurableAssistants::Live.attach`). The same connection
  sends an answer if the call used `ask_agent`.
  After a transient refusal or early closure, it reattaches once to the same
  session without answering again. An initial HTTP 400 gets that one extra
  attempt after 250 ms; a second refusal stops. It keeps captured text, drops
  replayed fragments, and marks the result potentially incomplete.
- **Diagnostics.** The webhook logs whether each caller identity header was
  present on the signed offer, never its value. The job logs when the sideband
  opens, whether it failed at connect or read, the HTTP status or WebSocket
  close code if the client exposes one, the error class, and transcript
  hand-off. For a refused upgrade it logs the HTTP protocol and a provider
  error code only if on a fixed list. No header values, response bodies or
  messages, close reasons, or spoken words are logged.
- **What arrives.** The caller's words (`session.input_transcript.delta`) and
  the agent's (`session.output_transcript.delta`), in their order on the call,
  one line per turn (`Agent::VoiceCall::Transcript`), as a message from "your
  phone line's caller", since Rails never reads who called: untrusted, as any
  text is. It is cut to the thread's limit
  like any message.
- **When nothing was heard.** The message says "Transcript unavailable" and
  why: the sideband couldn't be reached or broke, or the call ended with
  nothing transcribed. If the connection closed before the call ended, what
  was heard comes with a note that it may be incomplete. Nothing is guessed.
- **The summary** is the agent's own reply, in its own model, not a separate
  call.
- **One thread per call.** A listening call holds a job thread for as long
  as the call lasts. Its jobs go on the `voice` queue, which has a worker of
  its own (two threads), so calls wait behind no sweep; the worker for every
  queue may take one too, as it may any queue's. OpenAI publishes no fixed
  limit on a call, so the app stops listening after two hours of its own and
  says the transcript may be incomplete. The app keeps no transcript of its
  own, only the thread's message. A call whose accept is `unknown` is not
  listened to. A job worker stopped mid-call, as by a deploy, loses that
  call's transcript, and no message says so.

### Calling out

The bound agent gains `place_call` (looked up) once two more settings are
set: `VOICE__CALL_TRIGGER_URL`, the gateway's call trigger on its private
address; and `VOICE__CALL_TRIGGER_TOKEN_FILE`, the path of a read-only file
holding its bearer (mounted into the job container, never an environment
variable or credential). No other agent has it.

The bearer is read from its file at each call, one trailing newline
stripped, so a rotation needs no restart. A missing, empty or unreadable
file, or one holding anything but one URL-safe token, refuses the call in
its job, before any request. The token is never logged
or named in an error or result.

- **Any number.** There is no list of allowed numbers: the agent may call
  any number it names. A call reaches someone else, so a workspace on the
  normal policy asks first; one that approves everything, its own choice or
  the install's, doesn't.
  The number is checked only as data, in international form (E.164): an
  optional `+`, then 7 to 15 digits, the country code first and never 0.
  Anything else (spaces, letters, punctuation, a leading 0) is refused
  before any request. The trigger must read the number from the body: one
  that dials only its own fixed number ignores the body and rings that
  number instead, so point `VOICE__CALL_TRIGGER_URL` at a trigger path that
  takes a destination.
- **One request, never again.** A call runs in the job role
  (`InvocationCallJob`, queue `calls`), never inside a web request: one
  `POST` to the trigger with the bearer and the number's digits as a JSON
  body (`{"number":"442071838750"}`, the `+` dropped), waiting up to 5 s
  to connect and 45 s for the answer. Its result in the thread is
  `carrier_answered` (202: the carrier answered; that alone shows neither
  that the person heard the agent nor two-way sound), `uncertain` (409: busy,
  closed, or it rang and nobody answered; 504, its phone system lost after
  the dial was asked for; any status the trigger doesn't document; or the
  request cut off or timed out after sending: the phone may have rung), or
  `failed` (401, a refused token; 503, its phone system unreachable before
  the dial was asked for; 400, 404, 405 or 413, the trigger's own refusals;
  or no connection: nothing was dialled). The codes are the trigger's own
  status table; a trigger from before that table gives 503 after a dial too,
  so run one that has it. None is retried, by its job or the
  ledger. A job lost mid-call ends, past `Invocation::RUN_LIMIT`, as a call
  that may or may not have happened.
- The trigger's address is private by design, so it is not checked as a
  connector's address is. The tool call is the record of each call; no
  voice-call row is made, as those hold OpenAI's inbound offers.

## Setting it up

1. **A number.** In voip.ms, order a DID in the area you want, and turn on
   SMS/MMS for it in the number's settings.
2. **Texts in.** In the same settings, turn on SMS-to-email and give the agent's
   own address (`docs/email.md`). Each text then reaches its thread as a text
   from the sender's number, told to answer with `send_text`: the app knows
   voip.ms's forwarding by its sender, `sms@voip.ms`, and the number in its
   subject (`AgentsMailbox`). Like any mail it could be forged, and a text
   back still asks the person first, unless the install approves everything.
   A text arrives in seconds: it lands in a box whose server says the moment
   it does (`docs/email.md`, "How soon it arrives").
3. **Voicemail.** Make a voicemail box, set the DID's routing to it, and set
   the box to email the agent's address, with a transcript if wanted.
4. **The API.** In voip.ms, Main Menu → SOAP & REST/JSON API: set an API
   password, enable the API, and allow only the install's public address.
   Put the account's email and that
   password in the install's secrets as `VOIPMS__USERNAME` and
   `VOIPMS__PASSWORD`.
5. **The agent.** On the agent's Channels page, under Phone, enter the number.
   The agent learns it in its instructions and gains `send_text`. Clear it to
   take both away.

## What the app allows

- **From its own number only.** The app sends from the number on the agent;
  the model names only whom to text and what to say. One North American
  number a text.
- **The person first.** Each text asks the person, as an email to outside
  does. Answering "Always" lets the agent text that number unasked from then
  on, or anyone, as the person chooses; Permissions on the agent's page lists
  and removes them. A workspace that approves everything (its own policy,
  or `APP__APPROVE_EVERYTHING` as the install's default, docs/permissions.md)
  skips this card, so a text, even one answering a forged text, goes out
  unasked.
- **At most 20 in any 24 hours** (`Tool::SendText::DAILY_LIMIT`). Past that
  the tool refuses, and the person gets one notification. An agent texting
  that much is more likely stuck in a loop than busy.
- **Every text is in the thread,** as the tool call that sent it, with whom
  it went to and what it said.
- Up to 160 characters goes as one SMS; longer goes as one MMS, up to 2,048.
- **The workspace's rules.** A text from a number the workspace routes to
  another of its agents reaches that agent instead, and a member who named
  one agent as their only contact is texted by no other (`docs/contacts.md`).

## When voip.ms is slow to answer

voip.ms has taken 17 to 19 seconds to answer a send, and sent it; once it
took a 172-character MMS and never answered in time, and the call was
recorded failed. So each text is recorded, with a key of its own
(`Dispatch`), before voip.ms is asked, and a send waits 45 seconds for its
answer (15 to connect). An explicit HTTP 5xx fails the send immediately. It
does not start the unknown-send workflow, and the app makes no automatic
retry. Before retrying, check voip.ms's message log and record the result
on the failed text's card. Until someone does, the app refuses an identical
send; if it went, don't resend.

If the connection breaks after the request starts or the response is
unreadable without an explicit 5xx, the text may already have gone. The app
looks for the same words in the texts (or MMS) the agent's own number sent
that recipient since the send began.

- **Found:** the text was sent, with voip.ms's id, as if it had answered.
- **Not found, or the lookup fails:** the call ends "unknown", with the
  send's key: it may have gone, so the agent is told not to send it again.
  It includes the safe send and lookup reasons, never the provider body or raw exception.
  It counts against the day's 20, as a sent text does. It is never reported
  as failed, which would invite a second send. The app keeps asking voip.ms
  in the background, two minutes on and then less often, up to an hour
  apart, and tells the agent in its thread once it knows:
  - **listed:** it went, with voip.ms's id;
  - **listed nowhere an hour on, or voip.ms can't be asked for a day:**
    still unknown. It is never reported "not sent": voip.ms may list a
    text with other words than those sent, and "not sent" would invite a
    second one. The agent is told not to send it again and to ask its
    person. The text's card in the thread says, in one line, that whether
    it went is still unknown, with **It went** and **It didn't go**. The
    person checks the phone or the number's message log in voip.ms and
    presses one; the card then says who checked and what they said, and
    the agent is told once. After "It didn't go" it may send the same
    words again.
- **Never connected, or refused:** nothing was sent, and the call fails
  saying so.

A text is sent at most once whatever happens:

- A replay of the call reads what was recorded, and one lost mid-send fails
  as lost rather than sending again (`Invocation::RUN_LIMIT`); its recorded
  send is checked as above, and the agent told.
- A call whose send was recorded never sends again, even if its job runs
  twice.
- The agent retrying the same words to the same number is refused, naming
  the first, while that one is still being checked, is still unknown (until
  a person says it didn't go), or went in the last 10 minutes
  (`Dispatch::REPEAT_WITHIN`). The same words after that are a new text.

## A workspace's own voip.ms account

A shared workspace may text through a voip.ms account of its own rather than
the install's, as when its number was ordered on another person's account.
Its owner, on the workspace's page under Texts, names the password manager
entry that holds that account's API username (its email) and API password
(`docs/passwords.md`); the entry must be shared with the workspace's agents,
and must be saved with voip.ms's address (voip.ms or a subdomain of it). The
page shows the owner the entry's name and never its contents; members see only
that the workspace has an account of its own, not the entry's name (as with its
Campfire), and cannot change it. Clearing it ("Use the install's account")
goes back to the install's.

- Each request to voip.ms, whether to send or look up a text or to read or
  change number settings, reads the entry from the vault as the calling agent
  and keeps nothing (`Workspace#voipms_account`). A text lookup uses the same
  account the send went through.
- If the vault can't find the entry, it is saved for another site or no
  address, or it lacks its username or password, the request is refused.
  The install's account is never used instead.
- Where the install has no `VOIPMS__USERNAME`, an agent in a workspace with
  its own account still texts.
- The entry is reserved like a mail account's: no agent can list it, fill it
  in a browser or use it as a key (`Agent#reserved_sign_in?`).
- Texts still come in as before, by that account's SMS-to-email forwarding to
  the agent's address. A number is one agent's across the install, whichever
  account it is on, and must be on its workspace's account: moving an agent to
  a workspace with another account does not move its number. The move page
  says so, in one line beside each such workspace, when the agent has a
  number; the move still goes ahead.

## Checking and changing a number's settings

For a number move, switch on `phone_number_settings` and, if needed,
`change_phone_number_settings` one by one on the agent's Tools page. The
agent looks them up when needed.

- `phone_number_settings()` reads the agent's own number. Pass `number` (ten
  digits) to read another number on the same voip.ms account, or `list: true`
  to list all the numbers on that account. Neither requires the agent to have
  a number of its own. A number voip.ms doesn't return is not on the account.
  The list shows the number, routing, voicemail mailbox and SMS status and
  destinations. A single read also shows the mailbox email and attachment
  settings, and whether SMS callback, webhook and SMPP are enabled. It never
  shows their URLs or credentials, or the mailbox PIN.
- `change_phone_number_settings` changes only the agent's own number, and
  only `sms_forward` (ten digits), `sms_email` (one address) or
  `voicemail_email` (comma-separated addresses, up to 255 characters). Supply
  at least one setting. An empty string turns that SMS forwarding option off
  or clears the mailbox email. A mailbox another number also uses is refused:
  its email is the mailbox's, so changing it would change theirs. The tool
  does not change call routing.
- Every change asks for approval, even in a workspace that approves
  everything. The card shows the old and proposed values. If those values
  change before the write, the card asks again. The result shows the values
  before and after, with a warning if voip.ms doesn't report the requested
  result. To undo, ask to set the `before` values back.
- voip.ms replaces a whole SMS or mailbox record on each write. The app
  carries the other settings forward, refuses an incomplete record, and
  refuses SMS changes while SMPP is enabled (its password can't be read). A
  voicemail-email change needs an assigned mailbox. Nothing is changed if
  either requested replacement fails these checks.

## Greeting adapter

There is no user-facing greeting command. The adapter can look up one recording
by ID and return only its ID and name. To create one, it takes the approved
SHA-256 and the bytes already in memory, verifies the digest, and sends those
same bytes as Base64 without an existing ID. It never replaces a recording.

Changing one mailbox's unavailable greeting requires the expected current
recording ID. The adapter reads the mailbox first, refuses incomplete or masked
settings, and carries the other writable settings forward in memory. It does
not change the mailbox email, PIN, transcription, or routing. A lost response
does not trigger another write; check the provider state before acting again.

On a JSON refusal, the adapter reports the HTTP code and the status VoIP.ms
returned, if it is a short lowercase code. A code that could echo the API
username or password (its letters contain theirs, or theirs contain its) is
shown only when it is on a fixed list from the open-source VoIP.ms client.
Anything else is `unrecognised status`; no response body or other field is
quoted.

## The account's password

voip.ms has no narrower key: the API password can read every message and
change or cancel the account's numbers. So:

- Only `lib/durable_assistants/voipms.rb` holds it, from the install or its
  workspace's vault entry. The connector allows `sendSMS` and `sendMMS`,
  `getSMS` and `getMMS` to find uncertain sends, `getDIDsInfo` and
  `getVoicemails` to read number settings, `setSMS` and `setVoicemail` for the
  guarded changes above, and `getRecordings` and `setRecording` for the greeting
  adapter. Its private recording read accepts `getRecordingFile` for one
  recording ID. No route, tool, or caller exposes the audio or uses that read.
- The API password and mailbox PIN go only in multipart POST bodies sent to
  voip.ms, never in URLs, logs, tool results, approval cards or the sidecar.
- voip.ms takes API calls from the allowed address alone, so the password is
  no use from anywhere else.
- Failure messages use one safe shape for every request. A provider refusal
  shows its HTTP code and the status code VoIP.ms returned, unless that code
  could echo the API credentials (see above); then it reports `unrecognised status`. Connection, sending and response
  timeouts are distinguished. No provider body, raw exception, phone number,
  vault entry name or credential is repeated in an error. A text that might
  have gone can be looked up, never sent again automatically. For an uncertain
  settings or greeting write, read back before trying again.
