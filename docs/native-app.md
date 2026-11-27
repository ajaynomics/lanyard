# The phone app

The iPhone app (`ios/Phone/`) is a Hotwire Native shell over the web app.
Rails draws every page; the app gives them native tabs, navigation bars,
sheets, buttons, toasts and haptics. Building it: `ios/BUILD.md`. Uploading
it: `ios/TESTFLIGHT.md`.

## Tabs

`HotwireTabBarController`, each tab with its own stack. Rails lists the tabs
in the path configuration's settings (`PathConfiguration::TABS`, below):
each its id, title, SF Symbol (`ios_image`, filled when selected) and first
page (`url`). The app decodes them (`Phone/AppTab.swift`, tested by
`AppTabTests`) each time it builds its tabs, from the configuration it holds
then: the bundled copy, or the install's own from the last launch. So a
renamed tab shows from the launch after Rails changes it, with no new build.
Without tabs it can read, the app keeps its own copy of today's list:

| Tab | Starts at | Why |
|---|---|---|
| Agents | `/` | The list of agents and their threads: where most time goes. |
| Needs you | `/approvals` | Every card waiting on the person across all agents in all their workspaces, the Watch's list on the phone. Its badge counts those cards (`layouts/_badge`). |
| Settings | `/settings` | The web's own list of settings: one row per place, each a sheet, then Version and Sign out (below, "Settings"). |

Every sheet has a close button at its leading edge (`WebViewController`):
Cancel where the path configuration says `close: cancel` (a form, `/new` and
`/edit`, whose submit is on the right, and signing in), Done elsewhere
(`SheetClose`). Swiping a sheet down closes it too, except signing in.
A page that fails shows the app's own error screen (`ErrorScreen`) with Try
again, which loads it afresh; only a 401 opens the sign-in sheet
(`SessionGate`). Fresh tabs whose first page neither loads nor fails within 15
seconds get the same screen (`FirstVisitWatch`).
Only the selected tab loads until another is chosen. A pushed thread hides
the tab bar, so its composer sits at the foot.

## Settings

The Settings tab is the web's `/settings` (`PathConfiguration` `ios_v3`):
the same list as the web's sidebar (`settings_groups`), so Rails decides who
sees Models (admins) and Wallet (where Link is set up). In the app the page
adds what the app's own screen had (`settings/_native_rows`,
`settings_value`). Each place opens as a sheet:

| Row | Opens |
|---|---|
| You | `/settings/account`: name and email |
| Notifications | `/settings/notifications`: on this iPhone, and Notify me about. The row says what the page says: On for a token this session posted, unless the app has said since that iOS refuses them; Off once the app last reported iOS refused; Not set up otherwise, Not available without an APNs key. Off, it opens `app-settings:` instead, the iPhone's Settings for the app, the one place that can allow them: Hotwire Native hands an address on another host to iOS. |
| Apple Watch | `/settings/watches`: each Watch with Revoke, or none and how to connect one. The row says Signed in while a Watch holds a token Rails would take, Not signed in otherwise: a page can't ask WatchConnectivity whether one is paired. |
| Models, Invitations, Workspaces, Connectors, Helpers, Usage, Wallet | Their pages |
| Each agent | Its settings |
| Version | Nothing: the build, from the app's user agent (`Lanyard/0.1(12)`), and the install it talks to |
| Sign out | Asks first, then signs out here, the Watch and this iPhone's notifications |

**Sign out** asks in iOS's alert, then sends `DELETE /sign_out?phone=forget`:
Rails revokes the Watch's tokens, forgets the notifications token this session
posted, and ends the session. Once Rails has answered, the page tells the app
through the `session` component (`native/session_controller`, event
`signed-out`; `Phone/Bridge/SessionComponent.swift`), which forgets its
cookies, tells the Watch and starts its tabs afresh, whose first page's 401
opens the sign-in sheet. A sign-out that never reached Rails tells the app
nothing: the person is still signed in, and sees so.

The statuses change in their sheets, in iOS's Settings or on the Watch, so the
page follows `Current.user, :settings`, which a notifications token, a reported
refusal and a Watch connected or revoked each refresh (`Push::Device`,
`Push::Attempt`, `Watch`): closing Notifications' sheet after a refusal, the
row beneath already says Off. The page also reloads when pulled, and when the
app comes back to the front, now if it shows, else when it is next chosen
(`SceneController`), for what changed while the app was away.

A build reading `ios_v2` draws its own screen instead, from `GET
/settings.json` (`SettingsController`), and signs out with `DELETE
/sign_out.json` naming its token. Both stay for builds already installed.

"On this iPhone" means this phone. Each device row keeps the private digest of
the session that posted its token (`Push::Device.this_session`), never the
session id or the token: the page's Turn on and the app's own post send the
same web-view cookies, so the page says On only when this session's token is
held. A row from before has no digest until the app posts its token again, at
its next launch or return, and until then the page offers Turn on, which
posts it.

## Path configuration

`PathConfiguration` (`app/models/path_configuration.rb`) says which pages
open as sheets and which push. Rails serves each version at
`/configurations/<version>.json` (public, cached for an hour); the app bundles
the same JSON (`ios/Phone/path-configuration.json`) for a launch with no
network, and a test checks the two match. Regenerate the bundled copy with:

```shell
bin/rails runner 'puts JSON.pretty_generate(PathConfiguration.fetch("ios_v3").as_json)' > ios/Phone/path-configuration.json
```

- `ios_v1`: what builds already out read. Leave it alone.
- `ios_v2`: forms (`/new`, `/edit`), settings, an agent's own pages,
  connectors, subscriptions and workspaces open as large sheets; a waiting card
  (`/approvals/:id`) as a half-height sheet; `/sign_in` as a sheet that can't
  be swiped away; a screen (`/screen`) full screen. Lists and threads push,
  with pull to refresh. `/native/settings` is the app's own screen
  (`view_controller: settings`). Installed builds read it: leave it alone.
  Forms and signing in say `close: cancel`, which a build that predates it
  ignores.
- `ios_v3`, what the app reads now (`AppDelegate`): `ios_v2` with the
  Settings tab a web page: no `view_controller`, and `/settings` itself
  pushes, with pull to refresh, as the tab's first page. Every other settings
  page is still a sheet. Its settings list the tabs (`tabs`), Settings at
  `/settings`; a build that reads no tabs ignores them.

A change the installed app can live with goes in the current version. One it
can't (a new native screen, say) needs a new version, read by a new build.

A controller answering a form from a sheet uses Turbo Rails' native redirects,
so the sheet closes and the page beneath shows the result:
`refresh_or_redirect_to` (close and reload beneath, as Needs you after a card
is answered), `recede_or_redirect_to` (close or go back) and
`resume_or_redirect_to` (close, nothing else). A browser gets the ordinary
redirect.

## In the app, the page steps aside

When `hotwire_native_app?` (the app's user agent), the layout:

- leaves out the web's header and sets `html[data-native-app]`, under which
  `native.css` hides back links, the sidebar, headings and sign-out, which the
  app draws itself, and a thread's header draws no line of its own under the
  app's bar, which has its hairline already;
- titles the page with its own name alone (`page_title`), for the app's bar;
- leaves out view transitions: the app pushes and pops natively, with swipe-back;
- loads `native.css` and `native.js`, which a browser never downloads.

The app's text follows the phone's text size (`font: -apple-system-body` on the
root), so every `rem` grows with it, and shrinks: at iOS's smallest sizes 1rem
is 14 or 15 pixels. iOS magnifies the page into a field under 16 pixels when it
takes the focus, and stays zoomed, so the page seems to run off the screen. On
a touch screen every field's text is at least 16 pixels (`--text-field-min`,
tokens.css); a field that sets its own size takes the larger of the two. No page may scroll sideways at any size:
what is wider than the screen wraps (`overflow-wrap: anywhere`) or scrolls in
its own box (code, tables), and a field's width is a percentage capped in
`rem`, never a fixed `rem` alone, so it shrinks with its row; a grid's single
column is `minmax(0, 1fr)`, since an automatic one grows to its widest
content (a button's words never wrap). Never hide a
page's overflow to pass: `test/system/native_overflow_test.rb` visits every
main page at 390 wide, light and dark, at iOS's default (17px), largest (23px)
and first two accessibility (28px, 33px) body sizes, and names what sticks out. Chromium
ignores `-apple-system-body`, so the test sets each size on the root itself;
a phone is still the last word.

Signed out, a page answers 401 in the app (`Authentication`), and the app opens
its sign-in sheet; a browser is still sent to `/sign_in`. Signing in from the
sheet ends in `refresh_or_redirect_to`: the app sees the refresh, closes the
sheet and starts its tabs afresh, signed in. Signing in through the browser
sheet (NativeSignIn) ends the same way, when the sheet reports success.

## Bridge components

`native.js` loads Bridge Components' Stimulus controllers, from the public,
MIT-licensed `@joemasilotti/bridge-components` npm package (vendored by
importmap), and the app's own. Each hands part of a page to the app. When the
app lacks a component, the controller never loads and the page keeps its own
control: `native.css` hides a control only when the app has the matching
component (`html[data-bridge-components]`).

| Controller | Component (iOS) | Used for |
|---|---|---|
| `bridge--button` | Bridge Components, core | New agent and Add as bar buttons |
| `bridge--menu` | core | A thread's actions as the bar's menu |
| `bridge--share` | core | Share link, from that menu |
| `bridge--form` | core | A form's submit in the sheet's bar |
| `bridge--toast` | the app's (`NoticeComponent`), in place of core's | Flash messages as native toasts VoiceOver reads and UI tests find |
| `bridge--haptic` | core | A haptic on each answer and toast |
| `alert` (from `native.js`) | core | `data-turbo-confirm` as iOS's own alert |
| `bridge--notification-token` | Pro, or the app's fallback | Turning on notifications (Settings, Notifications) |
| `native--push-device` | the app's (`NotificationStatusComponent`) | Read the iPhone's notification permission without prompting or asking for a token |
| `bridge--phone-location` | the app's (`LocationComponent`, CoreLocation) | A single, explicitly shared foreground location fix |
| `native--approval` | the app's (`ApprovalComponent`) | Allow and Deny in a card sheet's toolbar; an answer that can't be sent says why on the page and offers them again (`failed`) |
| `native--tab-badge` | the app's (`TabBadgeComponent`) | How many cards wait on the person: the badge on the tab the page names (`needs-you`) and the icon's |
| `native--search` | the app's (`NativeSearchComponent`, core's `SearchComponent` under its own name) | The Agents list's search as the bar's own search field; it types into the page's field, which steps aside. Not core's `search`: builds already out answer that unchecked, so they keep the page's field |
| `native--session` | the app's (`SessionComponent`) | Signed out from the Settings tab: the app forgets its cookies, tells the Watch and starts its tabs afresh |
| `native--flash` | none (web only) | Show a flash as the toast |

The app registers its components once (`Phone/Bridge/Components.swift`):
Hotwire Native keeps only the last list.

**Pro.** Bridge Components Pro is a single-user licence: its source must
never be committed or published. The Swift package is a local folder on the
build Mac, which `ios/bin/generate` adds when it finds it (BUILD.md, "Bridge
Components Pro"). The one Pro component used is NotificationToken. A public
build uses the app's own `NotificationTokenFallback`, which has the same name
and messages. Pro's JavaScript controllers are already in the public npm
package, so the server needs nothing private.

## Share location once

Enable **Request phone location** on an agent's Tools page. The agent can
ask for one fix when you ask where you are or for something nearby. Open
the request on your signed-in iPhone and tap **Share location once**. The
first phone that starts the request is the only session that can answer it.
Each request closes after five minutes. If you have an older signed-in
session, sign out and back in after updating the iPhone app.

The iPhone requests When In Use permission only after that tap, and asks
CoreLocation for one fix. Leaving the screen or putting the app in the
background stops the request. No Watch, browser or nearby-place provider
receives the fix. The phone sends coordinates, horizontal accuracy and
the fix time straight to this install in a private request. The tool result
belongs to this conversation; the thread marks **Location shared**. The
thread and the agent distinguish denied app access, restricted app access,
and Location Services turned off on the phone. An unavailable fix,
**Don't share**, and **I don't have an iPhone** also return no coordinates.

## Notification art

iOS and watchOS select the installed app's AppIcon for native notices. A
mirrored iPhone notice is the iPhone app's notice. The badge count sent by
APNs is a number; the OS chooses how to show it. A push does not set a
different icon, and this app has no notification extension.

In browsers, the service worker supplies an icon in the install's accent
and a separate transparent monochrome badge. The Web Badging API count and
manifest are unchanged. Some platforms choose the installed web app icon
themselves. These surfaces are not yet checked on device.

## Notifications (APNs)

The web's Web Push stays for browsers. The app uses Apple's push service:

1. On Settings, Notifications, the phone first reads iOS's permission without asking
   for a token. If permission is already denied, the page says **Off** and links
   to the iPhone's Settings. Otherwise **Turn on** keeps the same tap-to-ask flow
   (notification-token); older builds continue to use that flow directly. The device
   token is posted to `POST /push/devices` (`Push::Device`), with the build's
   push service (`APNs/sandbox` or `APNs/production` in the user agent). The
   app also posts it itself each time iOS gives it (`Phone/PushRegistration.swift`):
   at launch and on each return to the app when notifications are allowed, so
   a phone already signed in, or turned on in iOS Settings, reaches Rails
   without a tap. When they are off in iOS Settings it reports `refused`
   instead, at launch and on each return, so a phone turned off there says
   Off, not On while Rails still holds its token. The report Rails receives
   last wins (`Push::Device#reported`), the page's own Turn on included: the
   phone's clock can be wrong, so Rails never orders reports by it.
   Rails keeps the token while refused: a notice sent then is not shown, and
   one sent after notifications are turned on again is. It posts it again
   after each sign-in: a token belongs to the phone, so it moves to whoever
   signs in. Rails takes a repeat without harm.
   Settings says what went wrong rather than nothing happening
   (`native/push_device_controller.js`): an app without the component (the
   tap says so at once; Turn on is no longer hidden), no answer within 15
   seconds of the tap (what Pro's component does when iOS refuses), an empty
   token, or a post Rails refused. The no-answer and empty-token messages say
   to check that notifications are allowed for the app in iOS Settings. The
   app's own component answers an empty token with `error` (`refused` or
   `failed`) when iOS refuses permission or fails to register
   (`PushRegistration.noToken`); the public `bridge--notification-token`
   controller passes on only `token`, so the page can't tell the two apart.
   Rails keeps what became of each try (below).
2. Each notice (`Push.deliver`) goes to browsers and iPhones, each only when
   its keys are set. A tap opens the thread, or the card itself when an agent
   needs the person (`url` in the payload; `Phone/PhoneRequests.swift`,
   `DeepLink`). Apple's `Unregistered` drops the device. A priority notice
   (a card waiting) has a sound and `interruption-level: time-sensitive`; a
   regular one is `passive`, with no sound or banner, so it goes only to
   Notification Centre, grouped by its thread's `thread-id`
   (`docs/design.md`, "Two levels"). Time-sensitive needs the app's
   Time Sensitive entitlement; without it iOS shows the notice as `active`.
   A tapped notice's page goes through `Phone/NotificationRouter.swift`. It
   keeps only a path on this install, and holds the latest tap until the
   app's tabs exist and a page of them has loaded without a 401: a launch
   from the banner doesn't know it is signed out until its first page
   answers, so a signed-out tap waits through the sign-in and opens once
   after it. iOS may call the notification delegate (the phone's
   `PushRegistration+Notices.swift`, the Watch's `NoticeDesk`) on a queue of
   its own, and UIKit wants its completion handler called on the main
   thread: each delegate method is `nonisolated`, reads what it needs where
   iOS calls it, and calls the handler from the main actor
   (`test/native_notice_isolation_test.rb`).
   A notice's buttons (`aps.category`, `Shared/NoticeRoute.swift`): Allow
   once and Decline on a small card, Decline on any other approval, Reply
   with words on a reply. The app registers them at launch and answers in
   the background, with its web session, the same JSON the Watch sends
   (`Phone/NotificationActions.swift`), so Rails holds them to the Watch's
   card: the version the notice named, never a long card allowed, never
   Always. What Rails confirms says nothing; anything else is a notice of
   its own, "Not done", whose tap opens the card or the thread
   (`docs/design.md`, "A notice's buttons").
3. The app's Sign out (`DELETE /sign_out.json`, `phone=forget`) revokes the
   Watch's tokens and forgets this phone's device token.

### Why a phone has no device

Each Turn on's outcome reaches Rails (`POST /push/attempts`, `Push::Attempt`),
with a code where there is one, the request's user agent, and the time. Never
the device token: only `Push::Device` keeps that.

| Outcome | Who says it | Code |
|---|---|---|
| `registered` | Rails, the first time a phone's token comes for a person | none |
| `no_component` | the page: the app has no notification-token component | none |
| `no_answer` | the page: nothing within 15 seconds of the tap (Pro's component when iOS refuses, or a tap that never reached the app) | none |
| `rejected` | the page: Rails refused the token, or the post never landed | the HTTP status |
| `refused` | the app (`PushRegistration.noToken`): the person said no to iOS's prompt, or did before (public build only; Pro's page says `no_answer`), or the app came to the front with notifications off in iOS Settings. The same refusal again is kept once | none |
| `failed` | the app: iOS couldn't register (`didFailToRegisterForRemoteNotificationsWithError`), on a tap or at a launch | iOS's error code |

The app's version is in its user agent (`Lanyard/0.1(12)`), from the build
that added it. Only each person's latest 20 are kept. Each also writes one
line to the log:

```text
Push attempt: failed (3000) user=1 app=0.1(12)
```

From a console (`bin/rails console`, or `kamal app exec -i 'bin/rails console'`):

```ruby
user = User.find_by!(email: "person@example.com")
user.push_attempts.order(:created_at).map { [ it.created_at, it.outcome, it.code, it.app_version ] }
user.push_devices.count
```

No attempt at all after a tap means the page's own post never reached Rails
either (signed out, say).

APNs sends nothing until the install sets all four (`config/apns.yml`):

| Variable | What |
|---|---|
| `APNS__KEY_ID` | The APNs auth key's id (Apple Developer, Keys) |
| `APNS__TEAM_ID` | The team that owns the key |
| `APNS__PRIVATE_KEY` | The key's `.p8` contents, PEM |
| `APNS__TOPIC` | The phone app's bundle id |

The App ID must allow Push Notifications, and the build must carry the
entitlement (TESTFLIGHT.md, "Notifications").
