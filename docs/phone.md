# Phone

An agent can have a phone number of its own and send texts from it with
`send_text`. The number is one of the install's voip.ms numbers (a "DID").
Texts to it, and its voicemail, reach the agent as email, through voip.ms's
own forwarding; nothing comes in by webhook. voip.ms is the one provider, with
no layer for others. Calls, incoming texts by webhook, and buying numbers from
the app are not built.

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
answer (15 to connect). If the answer still doesn't come, the app asks
voip.ms for the texts (or MMS) the agent's own number sent that recipient
since the send began, and looks for the same words:

- **Found:** the text was sent, with voip.ms's id, as if it had answered.
- **Not found, or the lookup fails:** the call ends "unknown", with the
  send's key: it may have gone, so the agent is told not to send it again.
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

- Each `send_text`, and each lookup of a send that timed out, reads the entry
  from the vault as the sending agent, for that one request, and keeps nothing
  (`Workspace#voipms_account`). The lookup asks the same account the send went
  through.
- An entry the vault can't find, saved for another site or for no address, or missing its
  username or password refuses the text, plainly not sent; the install's
  account is never used instead.
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

## The account's password

voip.ms has no narrower key: the API password can read every message and
change or cancel the account's numbers. So:

- Only `lib/durable_assistants/voipms.rb` holds it, the install's or a
  workspace's own (read from the vault each time), and it asks voip.ms for
  `sendSMS` or `sendMMS`, and `getSMS` or `getMMS` only to find a send that
  timed out (the agent's own number, that recipient, from the day before),
  at once and then from the background check, and nothing else, by POST so
  the password is never in a URL. That read is a narrow addition to what
  was a send-only module.
  `test/lib/voipms_test.rb` holds both.
- It never reaches an agent's computer or the sidecar.
- voip.ms takes API calls from the allowed address alone, so the password is
  no use from anywhere else.
