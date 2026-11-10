# Routes open to the internet

The app stands on its own, with no Cloudflare Access in front. Every route
needs a person signed in through Ajent whose email is on `ACCESS__EMAILS`, except
the ones below. `test/integration/open_routes_test.rb` walks every route and
fails if one answers without a signed-in person and is missing from this list.

An Ajent account whose email is not on the list gets no session at all, and
taking an email off the list ends that person's session at their next request
(`test/integration/ajent_sign_in_test.rb`).

Rate limits use Rails' `rate_limit`, counted in the app's cache (Solid Cache),
and answer 429. OmniAuth answers its two routes itself, before any controller,
so their limit is a middleware ahead of it, `DurableAssistants::SignInLimit`,
with the same store.

| Route | What guards it | Test |
|---|---|---|
| `GET /sign_in` | Shows only the sign-in button. 30 a minute per address. | `rate_limits_test.rb` |
| `POST /auth/ajent` | OmniAuth's request phase: needs the page's CSRF token, then sends the browser to Ajent. 10 per 3 minutes per address, counted ahead of OmniAuth (`DurableAssistants::SignInLimit`). | `rate_limits_test.rb` |
| `GET /auth/ajent/callback` | Ajent's signed answer, a verified email on `ACCESS__EMAILS`. 10 per 3 minutes per address, counted ahead of OmniAuth, so a forged state counts too. | `ajent_sign_in_test.rb`, `rate_limits_test.rb` |
| `GET /auth/failure` | Says sign-in did not complete. 30 a minute per address. | `ajent_sign_in_test.rb` |
| `POST /campfire/:token` | The agent's bot token, a secret; unknown tokens get 404. 60 a minute per token, 600 per address. | `campfire_bot_test.rb`, `rate_limits_test.rb` |
| `POST /concourse/:id/push` | Concourse's notice that an agent has new events. The agent's push token in `X-A2A-Notification-Token`, compared in constant time; anything else gets 401. It carries no mail and only wakes a read of the agent's event log. 60 a minute per agent, 600 per address. | `concourse_pushes_controller_test.rb` |
| `POST /agent/accesses` | The sidecar's callbacks. They answer only inside the host: anything that came through kamal-proxy or Cloudflare, or by a public name, gets 404. Then `PI_DURABLE__RAILS_TOKEN`. | `private_callbacks_test.rb` |
| `POST /agent/invocations` | As above. | `private_callbacks_test.rb` |
| `POST /agent/frames` | As above. | `private_callbacks_test.rb` |
| `POST /agent/syncs` | As above. | `private_callbacks_test.rb` |
| `POST /agent/sign_ins` | As above. | `private_callbacks_test.rb` |
| `POST /agent/files` | As above. | `private_callbacks_test.rb` |
| `POST /agent/uploads` | As above. | `private_callbacks_test.rb` |
| `GET /up` | Says only that the app booted. kamal-proxy polls it. Not limited. | `standards_test.rb` |
| `GET /manifest`, `GET /service-worker` | The app's name, icon and a static script. | — |
| `GET /icons/:id`, `GET /favicon.ico`, `GET /apple-touch-icon.png` | The icon, drawn in the install's accent (`Icon`): only the names in `Icon::VARIANTS`, as PNG, SVG or ICO; anything else is a 404. The same for everyone, and a browser asks for it before sign-in. | `icons_controller_test.rb` |
| `GET /configurations/:id` | A Hotwire Native app's path rules (`ios_v1.json`, `android_v1.json`; any other id is a 404): which screens open as a modal. Fixed, and the same for everyone. | `configurations_controller_test.rb` |
| `GET /connectors/client` | The install's Client ID Metadata Document (`Connectors::ClientsController`): its name, icon, home page and connector callback, with its own address as the `client_id`. A connector's sign-in server that supports these fetches it instead of taking a registration, so it must answer from the internet. The same for everyone. | `clients_controller_test.rb` |
| `GET /claude_subscription` | A fixed redirect to `/subscriptions`, which needs sign-in. | `open_routes_test.rb` |
| `GET /recede_historical_location`, `GET /resume_historical_location`, `GET /refresh_historical_location` | Turbo Native's empty pages. | — |

Refused by Rails itself: the Action Mailbox ingresses (`/rails/action_mailbox/…`)
answer 404 because mail arrives by IMAP and no ingress is set, and the
conductor (`/rails/conductor/…`) answers only in development. Active Storage's
links need the sign-in (`config/initializers/active_storage.rb`). A host in
`APP__REDIRECTS` gets only a redirect to `APP__URL`. The screen's websocket and
Action Cable need the session too.
