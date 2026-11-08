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
   back still asks the person first.
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
  and removes them.
- **At most 20 in any 24 hours** (`Tool::SendText::DAILY_LIMIT`). Past that
  the tool refuses, and the person gets one notification. An agent texting
  that much is more likely stuck in a loop than busy.
- **Every text is in the thread,** as the tool call that sent it, with whom
  it went to and what it said.
- Up to 160 characters goes as one SMS; longer goes as one MMS, up to 2,048.

## The account's password

voip.ms has no narrower key: the API password can read every message and
change or cancel the account's numbers. So:

- Only `lib/durable_assistants/voipms.rb` holds it, and it asks voip.ms for
  `sendSMS` or `sendMMS` and nothing else, by POST so the password is never in
  a URL. `test/lib/voipms_test.rb` holds both.
- It never reaches an agent's computer or the sidecar.
- voip.ms takes API calls from the allowed address alone, so the password is
  no use from anywhere else.
