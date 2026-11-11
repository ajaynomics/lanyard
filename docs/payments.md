# Payments by card

An agent can pay on a checkout page with a one-time card from its person's
[Link](https://link.com) wallet. The person approves every payment in Link's
app on their phone, for the exact amount, never in this app and never "always".
Link issues a card that works once, for that amount, and the card is typed
into the checkout page for the agent: the agent never sees its number.

Each person connects their own wallet. Nothing is shared between people.

## What a person sees

**Connecting.** Settings, then Wallet, then Connect Link. The page shows a
short phrase and a link to Link's page; the person signs in to Link there,
enters the phrase, and presses Done here. Link's app names the install by its
`LINK__CLIENT_NAME`. Disconnect ends the install's access at Link too, after
cancelling any payment still open.

**Switching it on.** `pay_by_card` is off for every agent until a person picks
it on the agent's Tools page. An agent of a person with no wallet connected is
refused before anyone is asked, and told to ask the person to connect one.

**A payment.** The card in the thread says what, to whom, on which site and
why, and where it stands:

| State | What it means |
|---|---|
| Requested | Being sent to Link. |
| Waiting | Link has pushed it to the person's phone. "Open in Link" opens the approval; it lasts 30 minutes. |
| Approved | Link issued a one-time card. The card shows its brand and last four digits, and when it was typed in. |
| Paid | The merchant charged the card. |
| Declined | The person declined it in Link. |
| Expired | Not approved within 30 minutes, or an approved card left unused until it ran out. |
| Cancelled | The person pressed Cancel here, before Link's answer or on an approved card not yet charged. |
| Failed | Link refused the request or the charge, with Link's reason. |

Cancel is offered while it is requested, waiting or approved. It asks Link to
close the request first, so a card that might still be charged is closed
before the card says it is. Link's own limits apply: up to $500 a payment, and
30 minutes to approve. The tool takes at most 50000 in the currency's smallest
unit ($500.00), so a larger amount is refused before Link is asked.

## How it works

1. The model calls `pay_by_card` with the amount (in the currency's smallest
   unit), currency, payee, the checkout page's https address and a reason.
   The call waits for the person (`Tool::PayByCard`, `asks :payment`), even
   where the install approves everything: nothing here can approve it.
2. `PaymentRequest` records it and `PaymentRequestJob` sends it to Link
   (`DurableAssistants::Link.create`), asking Link to push it to the person
   for approval. No approval policy is ever sent, so Link always asks. The
   request's key is the call's, so a retry is the same request.
3. The job asks Link every few seconds. Approved, the call runs and tells the
   model the amount, payee, site and the card's brand and last four digits.
   Declined, the call is declined. Not approved in 30 minutes, it is closed
   at Link and the call says nothing was paid.
4. The sidecar, seeing that the call pays (`pay: true`), asks Rails for the
   card once (`POST /agent/cards`, within five minutes of the call). Rails asks
   Link for it then; it is never stored. The sidecar passes it to
   `agent/guest/pay.mjs` on the Sprite in that one command's environment.
5. `pay.mjs` fills the page the agent last opened with `visit_website`, and
   its frames, a payment provider's card frame included, only if the tab is
   on the checkout's own site (or a name under it) over https. Each frame
   checks again as it fills: itself over https, and every page it sits in on
   the checkout's site. Card fields are found as a browser's autofill finds
   them, and masked once filled, so a screenshot shows dots. Once the number
   is in, the name on the card and the billing postal code are filled
   wherever the page marks them so (`cc-name`, `billing postal-code`) and they
   are empty. It never submits.
6. The model reads which fields were filled on which page, checks the total
   and presses the page's pay button with the desktop tool.
7. The job watches the approved card: charged, it is Paid; refused, it is
   Failed and closed at Link; left unused until it runs out, it is closed at
   Link and Expired.

A payment whose job was lost, its worker killed or its queue cleared, is asked
about again within five minutes (`PaymentRequestSweepJob`), so it still
expires and its card is still closed.

The card's number and security code are never in the model's input, the
tool's result, the conversation, Rails' database or a log line; errors from
Link never repeat its answer's body (`test/integration/link_payments_test.rb`,
`agent/test/card.test.mjs`). Rails keeps the card's brand and last four
digits, how long it lasts, when it was typed in, and the Link request's id.

**The limit.** As with saved sign-ins (`docs/passwords.md`), the card is
typed into a browser on the agent's own computer, where the agent also has a
shell. An agent set on it could read a filled field back before pressing pay.
What bounds that is Link: the card works once, for the approved amount, and
closes when cancelled, refused or unused. Approve a payment only for the
amount and payee you expect.

## Adding it to an install

1. Choose the OAuth client people sign in to Link with. Link's public client
   for agents works; so does one the install registers with Link.
2. Set `LINK__CLIENT_ID` to it, and `LINK__CLIENT_NAME` to what Link's app
   should call the install (the app's name otherwise).
3. To try it without real charges, set `LINK__TEST_MODE=true`: every request
   asks Link for a test card. Unset it for real payments.
4. Deploy. The Wallet page appears in Settings; people connect their own.

Without `LINK__CLIENT_ID`, there is no Wallet page and no agent can pay.

## What is not checked here

Tests and the browser check use a stand-in Link at the HTTP boundary and a
stand-in checkout page. Link's real API, a real merchant's checkout and a
payment provider's real card frame are checked only on a connected install.
