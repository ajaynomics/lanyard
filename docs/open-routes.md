# Routes open to the internet

The app stands on its own, with no Cloudflare Access in front. Every route
needs a person signed in through the Ajent sign-in provider whose email is on `ACCESS__EMAILS`, or
invited to (with an admin's approval) or a member of a shared workspace (`Admission`), except the ones below. `test/integration/open_routes_test.rb` walks every route and
fails if one answers without a signed-in person and is missing from this list.

An account at the sign-in provider whose email is not on the list gets no session at all, and
taking an email off the list ends that person's session at their next request
(`test/integration/ajent_sign_in_test.rb`).

Rate limits use Rails' `rate_limit`, counted in the app's cache (Solid Cache),
and answer 429. OmniAuth answers its two routes itself, before any controller,
so their limit is a middleware ahead of it, `DurableAssistants::SignInLimit`,
with the same store.

| Route | What guards it | Test |
|---|---|---|
| `GET /sign_in` | Shows only the sign-in button. 30 a minute per address. | `rate_limits_test.rb` |
| `POST /auth/ajent` | OmniAuth's request phase: needs the page's CSRF token, then sends the browser to the sign-in provider. 10 per 3 minutes per address, counted ahead of OmniAuth (`DurableAssistants::SignInLimit`). | `rate_limits_test.rb` |
| `GET /auth/ajent/callback` | The sign-in provider's signed answer, a verified email on `ACCESS__EMAILS`. 10 per 3 minutes per address, counted ahead of OmniAuth, so a forged state counts too. | `ajent_sign_in_test.rb`, `rate_limits_test.rb` |
| `GET /auth/failure` | Says sign-in did not complete. 30 a minute per address. | `ajent_sign_in_test.rb` |
| `GET /native_sign_in/new` | The phone app's sign-in, in its browser sheet: keeps the app's PKCE challenge in that browser's session and goes on to `POST /auth/ajent` from that page, as the sign-in button does, so OmniAuth's forgery check passes as usual. Anything but an S256 challenge gets a refusal page. 10 per 3 minutes per address, with the next route. | `phone_app_sign_in_test.rb` |
| `POST /native_sign_in` | The phone app trading its one-time code for a session in its own web view. The code is encrypted, lasts two minutes, is spent by its first try, and is good only with the verifier whose S256 challenge the sheet began with, which only the app holds. No authenticity token (the app posts with no page of ours before it), but a post a browser says came from another site (`Sec-Fetch-Site`) gets 403. 10 per 3 minutes per address. | `phone_app_sign_in_test.rb`, `native_sign_in_test.rb` |
| `GET /screen_passes/:token` | A one-time link to one conversation's screen (`ScreenPass`), which a person signed in here made and sent on. Only the token's digest is kept. The first device to open it gets a key of its own in an encrypted cookie, and only that device may open it again; any other gets 410. It lasts ten minutes and ends sooner by its maker or the visitor's Done. The page shows that screen and nothing else; its websocket at the same address also needs the device's key and the site's Origin, and is cut when the link ends. 30 a minute per address. | `screen_passes_test.rb` |
| `DELETE /screen_passes/:token` | The visitor's Done: the same token and the device's key end the link. Limited with the route above. | `screen_passes_test.rb` |
| `GET /sign_in_links/:token` | A one-time link for someone outside (a client's lawyer, say) to fill one empty saved sign-in (`SignInLink`), which an agent asked for, a person approved, and the agent sent on. Only the token's digest is kept. Opening it only shows a form (mail scanners fetch links), so it does not use the link up. It lasts 30 minutes; a used, expired or revoked link gets 410 and a plain page. No script, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`. 30 a minute per address. | `sign_in_links_test.rb` |
| `POST /sign_in_links/:sign_in_link_token/fill` | Its one submit: the same token, used up before anything is written, so a second submit, from any browser, gets 410. The sign-in goes from the request to the vault and nowhere else. No referrer means the browser sends `Origin: null`, so Rails' origin check is off for this one action; its `Sec-Fetch-Site` check still refuses another site's post. 10 a minute per address, counted before the token is looked up. | `sign_in_links_test.rb` |
| `GET /mcp_client_secret_setup` | A blank, uncached form for setting one empty conversation connector’s OAuth client secret. The authorized issuer shares a one-use link; only the browser sees its fragment and only a same-site script moves it into the form. No connector details or token in the response. No outside scripts, no referrer. 30 per minute per address. | `mcp_client_secret_setup_test.rb` |
| `POST /mcp_client_secret_setup` | The form’s CSRF token, the link token in the filtered body, and the client secret only. The server binds the token digest to one eligible connector and consumes it in the same transaction as the encrypted write. It expires in 15 minutes. Cannot replace a secret or sign in. No referrer or storage. 10 per minute per address. | `mcp_client_secret_setup_test.rb` |
| `GET /google_account_start` | Canonical app origin only. A blank page with no connector details. A local script reads the one-use fragment and removes it from the page URL. Opening the page does not start OAuth. No store or referrer. 30 per minute per address. | `google_account_start_test.rb`, `rate_limits_test.rb` |
| `POST /google_account_start` | Canonical origin, same-origin browser Fetch Metadata, and a URL-encoded form. The existing 40-character random, one-use `start_token` is filtered from logs. `preview=1` checks it by keyed digest without claiming it; a current Gmail grant link returns only the agent name as plain text, and a current legacy link returns empty 204. Malformed, unknown, used, replaced and expired tokens take the same indexed lookup, with no connector lookup, and get empty 410 with no-store and no referrer. Preview applies independent limits of 10 requests per minute per IP and 5 per minute per token digest, even for unknown tokens; either limit returns 429. The separate start request allows 10 per minute per IP and claims the token atomically. | `google_agent_grant_test.rb`, `google_account_start_test.rb`, `rate_limits_test.rb` |
| `POST /campfire/:token` | The agent's bot token, a secret; unknown tokens get 404. 60 a minute per token, 600 per address. | `campfire_bot_test.rb`, `rate_limits_test.rb` |
| `POST /telegram/:id` | Telegram's post of a message to an agent's bot (`TelegramBot`). The bot's own secret, which the app gave Telegram, in `X-Telegram-Bot-Api-Secret-Token`, compared in constant time; a wrong or missing secret and an unknown bot both get 404. The bot's id in the path is not a secret. 60 a minute per bot, 600 per address. | `telegram_bot_test.rb`, `rate_limits_test.rb` |
| `POST /concourse/:id/push` | Concourse's notice that an agent has new events. The agent's push token in `X-A2A-Notification-Token`, compared in constant time; anything else gets 401. It carries no mail and only wakes a read of the agent's event log. 60 a minute per agent, 600 per address. | `concourse_pushes_controller_test.rb` |
| `POST /voice/webhooks` | Off by default. A project-bound Standard Webhooks signature on the raw body, fresh within five minutes. Only Live SIP offers are recorded, from any caller; retries do not open another call. 60 per minute per address. | `voice_webhook_test.rb`, `rate_limits_test.rb` |
| `POST /agent/accesses` | The sidecar's callbacks. They answer only inside the host: anything that came through kamal-proxy or Cloudflare, or by a public name, gets 404. Then `PI_DURABLE__RAILS_TOKEN`. | `private_callbacks_test.rb` |
| `POST /agent/invocations` | As above. | `private_callbacks_test.rb` |
| `POST /agent/frames` | As above. | `private_callbacks_test.rb` |
| `POST /agent/syncs` | As above. | `private_callbacks_test.rb` |
| `POST /agent/sign_ins` | As above. | `private_callbacks_test.rb` |
| `POST /agent/cards` | As above. | `private_callbacks_test.rb` |
| `POST /agent/files` | As above. | `private_callbacks_test.rb` |
| `POST /agent/helpers` | As above. | `private_callbacks_test.rb` |
| `POST /agent/held_posts` | As above, scoped to the named conversation. | `held_posts_controller_test.rb` |
| `POST /agent/uploads` | As above. | `private_callbacks_test.rb` |
| `GET /up` | Says only that the app booted. kamal-proxy polls it. Not limited. | `standards_test.rb` |
| `GET /manifest`, `GET /service-worker` | The app's name, icon and a static script. | — |
| `GET /icons/:id`, `GET /favicon.ico`, `GET /apple-touch-icon.png` | The icon, drawn in the install's accent (`Icon`): only the names in `Icon::VARIANTS`, as PNG, SVG or ICO; anything else is a 404. The SVG may be asked for in another hue (`?hue=`, a whole number 0 to 360), a workspace's own (`Brand`); any other value, and every PNG and ICO, is the install's. The same for everyone, and a browser asks for it before sign-in. | `icons_controller_test.rb` |
| `GET /configurations/:id` | A Hotwire Native app's path rules (`ios_v1.json`, `ios_v2.json`, `ios_v3.json`, `android_v1.json`; any other id is a 404): which screens open as a modal. Fixed, and the same for everyone. | `configurations_controller_test.rb` |
| `GET /connectors/callback` | The existing callback looks up state only among the signed-in person's accessible connectors. Without a session it needs the exact, single-use state, compared in constant time; without it, the browser gets a plain 400 and no session or connector details. A reserved `gstart.` state instead takes the Gmail start branch: canonical origin, a still-valid state and its original browser cookie, S256, and the expected Gmail address before saving. An unknown, expired or used Gmail state gets 410. Both signed-out paths have no store or referrer and are rate limited (30 per minute per address per branch). The callback skips visit analytics and filters code and state. | `connector_callback_without_session_test.rb`, `google_account_start_test.rb`, `rate_limits_test.rb` |
| `GET /connectors/client` | The install's Client ID Metadata Document (`Connectors::ClientsController`): its name, icon, home page and connector callback, with its own address as the `client_id`. A connector's sign-in server that supports these fetches it instead of taking a registration, so it must answer from the internet. The same for everyone. | `clients_controller_test.rb` |
| `GET /claude_subscription` | A fixed redirect to `/subscriptions`, which needs sign-in. | `open_routes_test.rb` |
| `GET /recede_historical_location`, `GET /resume_historical_location`, `GET /refresh_historical_location` | Turbo Native's empty pages. | — |

Refused by Rails itself: the Action Mailbox ingresses (`/rails/action_mailbox/…`)
answer 404 because mail arrives by IMAP and no ingress is set, and the
conductor (`/rails/conductor/…`) answers only in development. Active Storage's
links need the sign-in (`config/initializers/active_storage.rb`). A host in
`APP__REDIRECTS` only redirects to `APP__URL`. The outside Google start and
its callback reject those aliases instead. The screen's websocket and
Action Cable need the session too.

The Google callback carries its code and state in the standard OAuth query.
Rails filters both. Do not collect callback query strings at a reverse proxy.
The account-start pages are excluded from visit analytics.
