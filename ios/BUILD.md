# Building the iPhone and Watch apps on simulators

For the Mac operator: an ordinary user, no sudo, no Apple account, no signing
team. Everything here is simulator-only and uses made-up records. The
TestFlight upload of both apps, signed, is a separate path: TESTFLIGHT.md.

- **LanyardPhone**: a Hotwire Native shell over the web app, with native tabs,
  sheets, bar buttons, toasts and Settings, which also gets the Watch its own
  token (`Phone/`; `docs/native-app.md`).
- **LanyardWatch**: native SwiftUI: waiting cards to allow or decline, an
  agent's thread to read, and a short reply to it, each a request to Rails
  with its token (`Watch/`); a notice's buttons do the same (section 9).
- **LanyardTests**: unit tests of the requests the Watch builds, its keychain
  item, the handoff and how each answer is read, and of the phone's sign-in
  addresses and requests, its tabs, its own requests to Rails (its push token
  posted as soon as iOS gives it, to a stand-in sender), notification links and
  buttons (a tapped notice handled on the main thread, NoticeTapTests; its
  page held until a page of the tabs loads signed in, then opened once,
  NotificationRouterTests), and
  error screen words (`Shared/`, `Tests/`).

The Watch calls Rails itself, with a token of its own. A Watch without one
asks the phone over WatchConnectivity; the phone, signed in, asks Rails for a
token with its web session and hands it over once. The Watch keeps it in its
keychain. WatchConnectivity carries nothing else, and no cookie leaves the
phone (`docs/design.md`, "The Watch, with its own token"). A notice's buttons
(Allow once, Decline, Reply) answer through the same requests: on the Watch
with its token, on the phone with its web session (`docs/design.md`, "A
notice's buttons"). Not yet checked on a device: a notice forwarded to the
Watch, its buttons there and dictation.

Needs: Xcode 26.3 (iOS and watchOS 26.2 SDKs), XcodeGen 2.46, network access
to github.com once, to fetch the Hotwire Native and Bridge Components packages.
Optionally the licensed Bridge Components Pro folder (section 2a).

## 1. Where the simulators find Rails

The simulators share the Mac's network, so `http://localhost:3000` in a
simulator, phone or Watch, is port 3000 on the Mac. Both apps are built for
that address (`LANYARD_BASE_URL`, in each app's Info.plist); the fixture
Rails must answer there.

**Recommended: run the fixture Rails on the Linux host and forward it over the
SSH session the operator already uses.** Nothing is installed on the Mac.

- Rails needs Ruby 4.0.9, SQLite, Node 22.19+ for the agent stand-in, and gems
  with native extensions. Whether the Mac has any of that is unknown;
  installing it without admin rights is a project of its own.
- The forward needs only that the Mac's sshd allows TCP forwarding (the
  default). It binds to the Mac's 127.0.0.1, so nothing else on the network
  sees it. Check port 3000 is free on the Mac first (`lsof -iTCP:3000
  -sTCP:LISTEN`); if not, pick another and build with that port.
- It binds 127.0.0.1 only, so each app's first try at `localhost` (IPv6,
  `::1`) is refused and it falls back to 127.0.0.1; the log shows the miss,
  and it is harmless. To skip it, add a second `-R '[::1]:3000:127.0.0.1:39471'`
  (or `-L` likewise). Keep `localhost` in `BASE_URL`: cookies are per host.
- Trade-offs: the apps work only while the SSH session is up, and every
  request crosses the link (fine for a walkthrough). Dropping the forward is
  also the honest "server unreachable" test in section 5.

On the Linux host, in this worktree (ports are examples; check they are free
with `ss -ltn`):

```shell
bin/setup --skip-server                       # gems and the development database, once
bin/rails runner script/watch_fixture.rb      # the made-up agent and four waiting cards
export PORT=39471 AGENT_PORT=39472
export PI_DURABLE__SIDECAR_URL=http://127.0.0.1:$AGENT_PORT
export PI_DURABLE__SIDECAR_TOKEN=$(openssl rand -hex 32) PI_DURABLE__RAILS_TOKEN=$(openssl rand -hex 32)
export FALCON_BIND=http://127.0.0.1:$PORT     # this host only, not the network
bin/dev                                       # Rails and the stand-in agent server (no paid model)
```

Then the forward, whichever way the SSH session runs:

```shell
# From the Linux host to the Mac:
ssh -N -R 127.0.0.1:3000:127.0.0.1:39471 <mac>
# Or from the Mac to the Linux host:
ssh -N -L 127.0.0.1:3000:127.0.0.1:39471 <linux-host>
# On the Mac, check: prints 401 (no session or token yet), which means Rails answered.
curl -s -o /dev/null -w '%{http_code}\n' -H 'Accept: application/json' http://localhost:3000/conversations.json
```

The fixture person is the development sign-in, `developer@localhost`. The
phone signs in through the web app's own page with **Sign in as a local
developer**, a route that exists only in development, either in its web view
(section 4) or in the browser sheet a device uses (section 7). Run the
fixture script again at any time to put the four cards back. Leave `OIDC__*`
unset for the fixture: the sheet then offers only the development sign-in.

## 2. Build

The operator has no screen to tap, so the walkthrough runs as UI tests:
`xcodebuild` builds once for testing, then runs each test on its own.

```shell
cd ios
export PHONE_UDID=<iPhone simulator UDID> WATCH_UDID=<paired watchOS simulator UDID>
export BASE_URL=http://localhost:3000
xcrun simctl list pairs        # find a paired iPhone + Watch; both UDIDs are listed

PHONE="platform=iOS Simulator,id=$PHONE_UDID"
WATCH="platform=watchOS Simulator,id=$WATCH_UDID"
COMMON=(-project Lanyard.xcodeproj -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO)
R=build/results; mkdir -p "$R" shots

bin/generate                   # xcodegen generate, with Bridge Components Pro if it is here (2a)
xcodebuild -resolvePackageDependencies -project Lanyard.xcodeproj -scheme LanyardPhone -derivedDataPath build/DerivedData
# The phone build also builds the Watch app (watchsimulator) and embeds it.
xcodebuild build-for-testing "${COMMON[@]}" -scheme LanyardPhone -destination "$PHONE" LANYARD_BASE_URL="$BASE_URL"
xcodebuild build-for-testing "${COMMON[@]}" -scheme LanyardWatch -destination "$WATCH" LANYARD_BASE_URL="$BASE_URL"
xcrun simctl boot "$PHONE_UDID" 2>/dev/null; xcrun simctl boot "$WATCH_UDID" 2>/dev/null

# Install the phone app, which carries the Watch app, then that same Watch app
# on the Watch. Installing over keeps the phone's sign-in.
APP=build/DerivedData/Build/Products/Debug-iphonesimulator/LanyardPhone.app
ls "$APP/Watch"                # must list LanyardWatch.app
xcrun simctl install "$PHONE_UDID" "$APP"
xcrun simctl install "$WATCH_UDID" "$APP/Watch/LanyardWatch.app"
```

If a build refuses to sign even ad hoc, add `CODE_SIGNING_ALLOWED=NO` and
report it: an unsigned app may then refuse to install, which is a finding,
not something to work around with an Apple account.

The Watch app lives inside the phone app, at `LanyardPhone.app/Watch/`, as
Xcode's own template does it. A phone app without it reports its Watch app as
not installed (`watchApp=false` in the phone's log, section 6), and
WatchConnectivity then drops the Watch's ask for a token. Installing the phone
app does not put the Watch app on the Watch simulator, so the second
`simctl install` does that, from the embedded copy. Then launch with
`xcrun simctl launch` and the bundle ids below.

A test run installs the app it tests: the Watch UI tests reinstall
`Debug-watchsimulator/LanyardWatch.app`, the same build as the embedded copy.
Reinstalling keeps the Watch's token: it lives in the keychain, not the app.

With no signing team the simulator's keychain may refuse to keep anything
(status -34018). The Watch's simulator build names a keychain group for that
(`Watch/Simulator.entitlements`). If the Watch's log still says `keychain save
failed status=…`, report it: the Watch then keeps its token only until it quits,
and asks the phone again on its next launch.

## 2a. Bridge Components Pro

The app uses one Pro component, NotificationToken, to ask iOS for
notifications. Pro is a single-user licence: its source is never copied into
this repository, which is public. The build Mac keeps the licensed copy in a
folder of its own, next to the checkouts:

```text
~/<builds>/bridge-components-pro-v0.14.0/    the Pro package (Package.swift at its top)
~/<builds>/<checkout>/ios/                   this folder
```

`bin/generate` looks for it at `BRIDGE_COMPONENTS_PRO_PATH`, by default
`../../bridge-components-pro-v0.14.0` from `ios/`. Found, it adds the folder
as a local Swift package (`project.pro.yml`) and builds with
`BRIDGE_COMPONENTS_PRO`, which picks Pro's component. Not found, it says so
and builds the public app, which uses its own `NotificationTokenFallback`
(same name and messages). Elsewhere:

```shell
BRIDGE_COMPONENTS_PRO_PATH=/path/to/bridge-components-pro-v0.14.0 bin/generate
```

Pro needs the public `bridge-components` at exactly 0.14.0, which
`project.yml` names too. Its JavaScript controllers are already in the public
npm package the web app vendors, so the server needs nothing from Pro.

Check after the first Pro build: the log says `Bridge Components Pro:
<path>`; the package resolves; and in the Pro build Settings, Notifications, **Turn on**
shows iOS's notification prompt. A simulator gets no device token without a
push entitlement, so the token reaching Rails is checked on a device only;
`PushRegistrationTests` checks the post the app builds from a token.

## 3. Screenshots

Every step of a UI test keeps a named screenshot in its result bundle.
`bin/export-shots` copies them into `shots/` under the step's name
(`xcrun xcresulttool export attachments --path … --output-path …`, then
renamed from its `manifest.json`):

```shell
for result in "$R"/*.xcresult; do bin/export-shots "$result"; done
```

To capture a screen outside a test: `xcrun simctl io "$PHONE_UDID" screenshot
--type=png shots/name-phone.png` (or `$WATCH_UDID`).

## 4. The walkthrough

Start with fresh cards: on the Linux host, `bin/rails runner
script/watch_fixture.rb`. A result bundle path must not exist yet, hence the
`rm -rf`.

```shell
# Unit tests.
rm -rf "$R/unit.xcresult"
xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardPhone -destination "$PHONE" \
  -only-testing:LanyardTests -resultBundlePath "$R/unit.xcresult"

# The phone signs in through the web page's development button.
rm -rf "$R/phone-sign-in.xcresult"
xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardPhone -destination "$PHONE" \
  -only-testing:LanyardPhoneUITests/PhoneSignInUITests/testSignInAsLocalDeveloper \
  -resultBundlePath "$R/phone-sign-in.xcresult"
# A test may close the app when it ends: bring it back to the front, signed in.
# It must be running when the Watch first asks for its token.
xcrun simctl launch "$PHONE_UDID" org.durableassistants.companion

# The Watch: its token (the first run waits up to two minutes for it); list;
# allow parking-spot; decline old-wifi; the long card has no Allow; open
# Watch fixture's thread, then Reply: send "Hello from the Watch".
# Screenshots: watch-03-list, watch-08a-thread, watch-08b-compose, watch-08-accepted.
rm -rf "$R/watch-walkthrough.xcresult"
xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardWatch -destination "$WATCH" \
  -only-testing:LanyardWatchUITests/WatchWalkthroughUITests/testWalkthrough \
  -resultBundlePath "$R/watch-walkthrough.xcresult"
```

Nothing runs when a card is answered: the agent's server never made these
calls, so the note stays. The message goes to the free stand-in, whose echo
shows in the agent's thread on the phone. Running the walkthrough again needs
the fixture script again: answered cards are gone.

## 5. Failures

Each is a simulation with its condition set up first; label them so. None may
show success Rails did not confirm.

```shell
# Phone app not running: the Watch, with its token, loads the list from Rails
# directly.
xcrun simctl terminate "$PHONE_UDID" org.durableassistants.companion
rm -rf "$R/without-the-phone-app.xcresult"
xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardWatch -destination "$WATCH" \
  -only-testing:LanyardWatchUITests/WatchFailureUITests/testListLoadsWithoutThePhoneApp \
  -resultBundlePath "$R/without-the-phone-app.xcresult"
xcrun simctl launch "$PHONE_UDID" org.durableassistants.companion

# Server unreachable: stop the SSH forward first (curl to localhost:3000 then
# fails), run this, then start the forward again.
rm -rf "$R/server-unreachable.xcresult"
xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardWatch -destination "$WATCH" \
  -only-testing:LanyardWatchUITests/WatchFailureUITests/testServerUnreachable \
  -resultBundlePath "$R/server-unreachable.xcresult"

# Answered elsewhere: the Watch opens the "Answer in one short sentence." card
# and logs READY; bin/answer-elsewhere then declines it through the web app's
# own form, as another browser would; the Watch's Allow must be refused.
rm -rf "$R/answered-elsewhere.xcresult"
# NSUnbufferedIO: xcodebuild writes the log as it goes, so READY is seen in time.
NSUnbufferedIO=YES xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardWatch -destination "$WATCH" \
  -only-testing:LanyardWatchUITests/WatchFailureUITests/testAnsweredElsewhere \
  -resultBundlePath "$R/answered-elsewhere.xcresult" > "$R/answered-elsewhere.log" 2>&1 &
for _ in $(seq 240); do grep -q "READY: answer the card elsewhere now" "$R/answered-elsewhere.log" && break; sleep 1; done
BASE_URL="$BASE_URL" bin/answer-elsewhere
wait; tail -40 "$R/answered-elsewhere.log"

# Revoked: on the Linux host, in this worktree, revoke every Watch token:
#   bin/rails runner 'Watch.active.find_each(&:revoke!)'
# The phone's app must not be running. The Watch says "Open Lanyard on your
# iPhone to reconnect." and logs READY; opening the phone's app then hands it
# a new token and the list loads again.
xcrun simctl terminate "$PHONE_UDID" org.durableassistants.companion
rm -rf "$R/revoked.xcresult"
NSUnbufferedIO=YES xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardWatch -destination "$WATCH" \
  -only-testing:LanyardWatchUITests/WatchFailureUITests/testRevokedTokenReconnectsThroughThePhone \
  -resultBundlePath "$R/revoked.xcresult" > "$R/revoked.log" 2>&1 &
for _ in $(seq 240); do grep -q "READY: open the iPhone app now" "$R/revoked.log" && break; sleep 1; done
xcrun simctl launch "$PHONE_UDID" org.durableassistants.companion
wait; tail -40 "$R/revoked.log"
```

If READY never shows in a log, the step after it runs once the test has
finished and the test fails on its own: report the log. Settings, Apple Watch, on
the phone then lists one Watch, the new token's, with when it was last used;
the revoked one is gone from the list.

Then export the screenshots (section 3). Report the Xcode and simulator
versions (`xcodebuild -version`, `xcrun simctl list runtimes`), and for any
failure the command and the last 40 lines of its output.

## 6. Logs, and a quick check without tests

Both apps log each step to the simulator's own log (subsystem
`org.durableassistants`; categories `phone-handoff`, `native-sign-in`,
`watch-link` and `watch-rails`): steps, kinds, counts, HTTP status and error codes, never a
body, cookie or token. A Watch request gives up after 20 seconds and says
so, so the Watch never sits on Loading.

After any run, collect them from each simulator:

```shell
for udid in "$PHONE_UDID" "$WATCH_UDID"; do
  xcrun simctl spawn "$udid" log show --last 10m --style compact \
    --predicate 'subsystem == "org.durableassistants"' > "shots/log-$udid.txt"
  # Everything the app processes logged, WatchConnectivity's own lines included.
  xcrun simctl spawn "$udid" log show --last 10m --style compact \
    --predicate 'process BEGINSWITH "Lanyard"' > "shots/log-$udid-all.txt"
done
```

A quick check, no taps and no tests: the phone is still signed in from the
sign-in test (its cookie persists), so install both apps as in section 2,
start them, and look. The logs show the last step reached.

```shell
APP=build/DerivedData/Build/Products/Debug-iphonesimulator/LanyardPhone.app
xcrun simctl install "$PHONE_UDID" "$APP"
xcrun simctl install "$WATCH_UDID" "$APP/Watch/LanyardWatch.app"   # the embedded copy
xcrun simctl terminate "$PHONE_UDID" org.durableassistants.companion 2>/dev/null
xcrun simctl terminate "$WATCH_UDID" org.durableassistants.companion.watchkitapp 2>/dev/null
xcrun simctl launch "$PHONE_UDID" org.durableassistants.companion; sleep 5
# Must say watchApp=true. False: the Watch app is not installed from the phone's view.
xcrun simctl spawn "$PHONE_UDID" log show --last 1m --style compact \
  --predicate 'subsystem == "org.durableassistants"' | grep 'watchApp='
# A Watch simulator left alone dims and suspends the app within seconds, and a
# suspended app logs nothing: look at it soon.
xcrun simctl launch "$WATCH_UDID" org.durableassistants.companion.watchkitapp; sleep 10
xcrun simctl io "$WATCH_UDID" screenshot --type=png shots/smoke-watch.png
xcrun simctl io "$PHONE_UDID" screenshot --type=png shots/smoke-phone.png
```

Then collect the logs as above. A healthy start reads, phone: `activated
state=2 paired=true watchApp=true`. A Watch getting its token reads, in
order: Watch `start token=none`, `asked the phone for a token`; phone `the
Watch asked for a token`, `cookies for the server: N`, `token asked: HTTP
201`, `token sent to the Watch`; Watch `token received`. Then the Watch loads
its cards directly: `send list`, `list HTTP 200 bytes=…`. A Watch that has
its token reads `start token=kept`, then `send list` at once. Report the last
line that appears, or send both log files.

If the phone says `watchApp=false`, reinstall both as above, then relaunch the
phone (a `watch state … watchApp=` line also shows a change while it runs).
If the phone says `not signed in yet`, run the sign-in test again and relaunch
the phone's app. If the Watch's log stops at `asked the phone for a token`,
the phone's app has not run since: launch it. If it stops at `send list` with
nothing after it, the app was suspended: launch it again and screenshot within
10 seconds. The UI tests keep the app in front for their whole run.

## 7. Signing in through the sheet (M4)

The phone app signs in in a browser sheet (`ASWebAuthenticationSession`), not
its web view, because identity providers refuse web views (TESTFLIGHT.md,
"Signing in inside the app"). This checks it on the simulator, against the
development fixture, whose sheet offers the development sign-in. The sheet
hands the app a one-time code just as the provider's return does on a real
install. Run sections 1, 2 and 4 first (the forward up, the Watch holding a token, both apps built and
installed, `PHONE_UDID`, `WATCH_UDID`, `COMMON`, `PHONE`, `WATCH` and `R`
set, from `ios/`). On the Linux host, check the fixture's scheme is the
simulator build's (the default, `org.durableassistants.companion`; nothing
to set unless `.env` sets `APP__NATIVE_SIGN_IN_SCHEME`).

```shell
xcodebuild -version; xcrun simctl list runtimes      # report both
# The build carries the scheme; must print org.durableassistants.companion.
/usr/libexec/PlistBuddy -c 'Print :NativeSignInScheme' \
  build/DerivedData/Build/Products/Debug-iphonesimulator/LanyardPhone.app/Info.plist

# 1. Unit tests, the sign-in's among them (NativeSignInTests).
rm -rf "$R/unit.xcresult"
xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardPhone -destination "$PHONE" \
  -only-testing:LanyardTests -resultBundlePath "$R/unit.xcresult"

# 2. Sign in through the sheet. The app starts signed out (its Debug-only
# launch argument clears its cookies), shows the sign-in page, opens the sheet
# on "Sign in with Ajent", accepts iOS's "Wants to Use … to Sign In" prompt,
# taps "Sign in as a local developer" in the sheet, comes back signed in, and
# is still signed in after a relaunch. Screenshots: phone-native-01-sign-in-page,
# -02-permission, -03-sheet-open, -04-signed-in, -05-after-relaunch.
rm -rf "$R/phone-native-sign-in.xcresult"
xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardPhone -destination "$PHONE" \
  -only-testing:LanyardPhoneUITests/PhoneNativeSignInUITests/testSignInThroughTheSheetAndStaySignedIn \
  -resultBundlePath "$R/phone-native-sign-in.xcresult"

# 3. The Watch's token, from the session the sheet started. On the Linux host,
# in this worktree, first take every Watch token away:
#   bin/rails runner 'Watch.active.find_each(&:revoke!)'
# Then, with the phone's app not running, the Watch asks again and the phone,
# opened, hands it a new token (section 5, "Revoked").
xcrun simctl terminate "$PHONE_UDID" org.durableassistants.companion
rm -rf "$R/native-watch-token.xcresult"
NSUnbufferedIO=YES xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardWatch -destination "$WATCH" \
  -only-testing:LanyardWatchUITests/WatchFailureUITests/testRevokedTokenReconnectsThroughThePhone \
  -resultBundlePath "$R/native-watch-token.xcresult" > "$R/native-watch-token.log" 2>&1 &
for _ in $(seq 240); do grep -q "READY: open the iPhone app now" "$R/native-watch-token.log" && break; sleep 1; done
xcrun simctl launch "$PHONE_UDID" org.durableassistants.companion
wait; tail -40 "$R/native-watch-token.log"
sleep 5
xcrun simctl io "$PHONE_UDID" screenshot --type=png shots/phone-native-06-watch-token-phone.png
xcrun simctl io "$WATCH_UDID" screenshot --type=png shots/phone-native-06-watch-token-watch.png
# The phone's log must show, in order: "sheet opened", "sheet came back with a
# code", "redeemed: signedIn(…)", then "cookies for the server: N" (N > 0),
# "token asked: HTTP 201", "token sent to the Watch".
xcrun simctl spawn "$PHONE_UDID" log show --last 15m --style compact \
  --predicate 'subsystem == "org.durableassistants" AND (category == "native-sign-in" OR category == "phone-handoff")' \
  > shots/log-native-sign-in.txt
grep -E 'sheet|redeem|cookies for the server|token asked|token sent' shots/log-native-sign-in.txt

# 4. Sign out: from the Settings tab's page (/settings), confirmed in iOS's alert, back to the
# sign-in sheet. Screenshot: phone-native-07-signed-out.
rm -rf "$R/phone-native-sign-out.xcresult"
xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardPhone -destination "$PHONE" \
  -only-testing:LanyardPhoneUITests/PhoneNativeSignInUITests/testSignOut \
  -resultBundlePath "$R/phone-native-sign-out.xcresult"

for result in "$R"/unit.xcresult "$R"/phone-native-*.xcresult "$R"/native-watch-token.xcresult; do bin/export-shots "$result"; done
```

Signing out from the app takes the Watch's token away too: Rails revokes it,
and the phone tells the Watch to forget it. The Watch asks again and gets a
new token once someone signs in on the phone.

What to report: the command and the last 40 lines of any step that failed,
the screenshots, and the log lines above. Known uncertainties, each a finding
rather than something to work around: iOS's prompt may name its button other
than Continue; XCUITest may not reach the sheet's page (it belongs to
Safari's view service), in which case run step 2 by hand
(`xcrun simctl launch "$PHONE_UDID" org.durableassistants.companion
-SignedOutForUITests`, then tap through) and screenshot each state with
`xcrun simctl io "$PHONE_UDID" screenshot`. Not checked by this: Google, a
passkey and a real provider in the sheet, which need a device and a real
install.

## 8. The phone app's walkthrough, light and dark

The app as a native app: signing in in its sheet; Agents, Needs you and
Settings; a thread; New agent's form as a sheet; a waiting card as a sheet
with Allow and Deny in its toolbar; Deny, and the toast it gives; native
Settings and a web settings page from it; Sign out, confirmed; and the error
screen with the server out of reach (a Debug-only launch argument points the
app at a closed port, so the forward stays up). Each step keeps a screenshot,
`phone-walk-light-NN-step` and `phone-walk-dark-NN-step`, as an attachment in
the result bundle. The look is held by a Debug-only launch argument
(`-LanyardAppearance light|dark`), as well as the simulator's own setting. On
iOS 26 a sheet's toolbar items float at its foot, with no bar behind them.

Run it after sections 4 and 5. It signs out, which revokes the Watch's token,
and each run denies one waiting card. Put the cards back first, on the Linux
host: `bin/rails runner script/watch_fixture.rb`. From `ios/`, with section 2's
variables set:

```shell
rm -rf "$R/phone-walkthrough.xcresult"
xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardPhone -destination "$PHONE" \
  -only-testing:LanyardPhoneUITests/PhoneWalkthroughUITests \
  -resultBundlePath "$R/phone-walkthrough.xcresult"
bin/export-shots "$R/phone-walkthrough.xcresult"
```

Afterwards the phone is signed out: sign in again (section 4) before any
Watch test.

What to report: the command and its last 40 lines if it failed, and the
screenshots. Not checked by this: notifications arriving and opening their
page, which need a device, the push entitlement and the install's APNs key
(`docs/native-app.md`, "Notifications").

## 9. A notice's buttons

A notice the simulator shows is one handed to it, not one from Apple: `xcrun
simctl push` delivers a payload file as Apple's service would. Each payload
is what Rails sends (`Push::Device`), for a fixture card. Run sections 1, 2
and 4's sign-in first, and put the cards back (`script/watch_fixture.rb`).

On the Linux host, in this worktree, print the payloads (made-up records only):

```shell
bin/rails runner '
  person = User.find_by!(email: "developer@localhost")
  person.invocations.waiting_for_approval.each do |card|
    buttons = Conversation::Notifiable::Buttons.for(card)
    payload = { aps: { alert: { title: "Watch fixture needs you", body: card.card_title }, "thread-id": "conversation-#{card.conversation_id}", category: buttons[:category] },
      url: "/approvals/#{card.id}", conversation_id: card.conversation_id, invocation_id: card.id, version: buttons[:version] }
    File.write("tmp/notice-#{card.call_id}.apns", payload.to_json)
  end
  conversation = person.agents.find_by!(name: "Watch fixture").conversation
  File.write("tmp/notice-reply.apns", { aps: { alert: { title: "Watch fixture", body: "A made-up reply." }, category: "REPLY" },
    url: "/conversations/#{conversation.id}", conversation_id: conversation.id }.to_json)
'
ls tmp/notice-*.apns    # allow-me, decline-me, every-time, phone-only, reply
```

Copy them to the Mac's `ios/build/`, then:

```shell
PHONE_APP_ID=org.durableassistants.companion
WATCH_APP_ID=org.durableassistants.companion.watchkitapp
# The phone, its app signed in (section 4) and in the background: press and
# hold the banner (or open it in Notification Centre) to see its buttons.
xcrun simctl push "$PHONE_UDID" "$PHONE_APP_ID" build/notice-allow-me.apns     # Allow once, Decline
xcrun simctl push "$PHONE_UDID" "$PHONE_APP_ID" build/notice-phone-only.apns   # Decline only
xcrun simctl push "$PHONE_UDID" "$PHONE_APP_ID" build/notice-reply.apns        # Reply, with a text field
xcrun simctl io "$PHONE_UDID" screenshot --type=png shots/notice-phone-buttons.png
# The Watch, if its simulator takes a push (it may not): the same files.
xcrun simctl push "$WATCH_UDID" "$WATCH_APP_ID" build/notice-decline-me.apns
xcrun simctl io "$WATCH_UDID" screenshot --type=png shots/notice-watch-buttons.png
```

What each should do, checked against Rails (`bin/rails runner 'puts
Invocation.where(call_id: %w[allow-me decline-me phone-only]).pluck(:call_id, :state).inspect'`):

- **Allow once** on allow-me: the card becomes approved. Pushed again, the
  same notice's Allow once is the answer already given.
- **Decline** on phone-only: denied. That card never offers Allow once.
- **Reply** with words on the phone: a message in Watch fixture's thread.
  On the Watch, Reply opens the app at the composer.
- After `script/watch_fixture.rb` again, the old files carry the old cards'
  ids: their buttons say not done (a new notice, "Already answered…" or
  similar), never done.
- A tap on the notice itself opens the card (or the thread) in the app.

Not checked by this: Apple's own delivery, a notice forwarded from a real
iPhone to a real Watch, and dictation, which need devices.

## 10. A tapped notice

Tapping a notice killed the phone app (TestFlight, 2026-11-16). This test
kills the app, waits for a notice's banner and taps it, so iOS itself
launches the app and calls its notification delegate. The notice is a local
one the Debug build schedules when launched with `-NoticeTapForUITests
/approvals` (`Phone/NoticeTapFixture.swift`). It needs notifications allowed:
a fresh install, or run it before `PhoneNotificationsUITests`, which refuses
them. Signed in by the test itself.

```shell
rm -rf "$R/notice-tap.xcresult"
xcodebuild test-without-building "${COMMON[@]}" -scheme LanyardPhone -destination "$PHONE" \
  -only-testing:LanyardPhoneUITests/PhoneNoticeTapUITests \
  -resultBundlePath "$R/notice-tap.xcresult"
bin/export-shots "$R/notice-tap.xcresult"
```

It passes when the app is still running with Needs you selected. Not checked
by this: Apple's push, a Release (TestFlight) build and a device's timing.
