# Uploading the iPhone app, with its Watch app, to internal TestFlight

For the Mac operator: an ordinary user (no sudo), Xcode 26.3, XcodeGen 2.46,
no Apple ID in Xcode. Xcode signs and uploads with an App Store Connect API
key. The build goes to **internal testers only**: no App Store review, no
external testers, no public link.

What gets built: **LanyardPhone with LanyardWatch inside it**, at
`LanyardPhone.app/Watch/LanyardWatch.app`, as in the simulator build. One
upload, one app record, one TestFlight invite: a tester installs the phone
app, and the Watch app comes with it. `project.testflight.yml` is
`project.yml` with Release signing for both apps, https only, and matching
version numbers (its header lists each change).

## What you need, and where it goes

None of these values belongs in the repository. Set them as environment
variables in your shell. Never echo them, never `set -x`, never paste them
into a log or a report.

| Variable | What it is |
|---|---|
| `PHONE_BUNDLE_ID` | The bundle id of the **existing** app record in App Store Connect (App Information, "Bundle ID"). It must match exactly; the upload is refused otherwise. The Watch app's id is this id plus `.watchkitapp`. |
| `DEVELOPMENT_TEAM` | The Apple Developer team id that owns that record (10 characters). |
| `LANYARD_BASE_URL` | The install's address, `https://…`, no trailing path. The app opens it at launch. |
| `NATIVE_SIGN_IN_SCHEME` | Optional. The app's own URL scheme for signing in ("Signing in inside the app"); the bundle id unless set. The install's `APP__NATIVE_SIGN_IN_SCHEME` must be the same, in lower case. |
| `MARKETING_VERSION` | The version testers see, e.g. `0.1`. |
| `BUILD_NUMBER` | Higher than every build already uploaded for this version. |
| `ASC_KEY_PATH` | **Absolute** path to the API key's `.p8` file (xcodebuild rejects a relative one). Keep it outside this repository. |
| `ASC_KEY_ID` | The key's id, shown beside it in App Store Connect. |
| `ASC_ISSUER_ID` | The issuer id, at the top of the same page. |

The first six are build settings. Instead of the command line you may put
them in `ios/Local.xcconfig` (ignored by git, read by `TestFlight.xcconfig`),
then drop them from the commands below. In an xcconfig `//` starts a comment:
write `LANYARD_BASE_URL = https:/$()/example.org`. The command line outranks
both files. The build's first step stops it if `LANYARD_BASE_URL` is not
https or `PHONE_BUNDLE_ID` or `DEVELOPMENT_TEAM` is empty.

**The build number** is `CURRENT_PROJECT_VERSION`, set per build on the
command line; no agvtool, nothing to commit. A UTC timestamp always rises:
`BUILD_NUMBER=$(date -u +%Y%m%d%H%M)`. Xcode does not renumber it
(`manageAppVersionAndBuildNumber` is false in the export options). Both apps
read the same two settings, so their version and build always match, which
App Store Connect requires of a Watch app and its phone app.

### The API key's role: Admin

Use a **Team** key with the **Admin** role (Users and Access, Integrations,
App Store Connect API). The export signs with an Apple-managed ("cloud
managed") distribution certificate, and only an Admin key may use one; there
is no separate switch for keys. With an App Manager or Developer key the
archive may succeed, but `-exportArchive` fails with "Cloud signing
permission error" ("You haven't been given access to cloud-managed
distribution certificates"), often followed by `No signing certificate "iOS
Distribution" found` or `No profiles for '…' were found`. A key's role cannot
be changed: create a new key.

### The Watch app's bundle id

The Watch app needs an App ID of its own, `$PHONE_BUNDLE_ID.watchkitapp`, in
the same team; the phone's exists already. Xcode should register it during
the archive, with no step of yours: `man xcodebuild` says of
`-allowProvisioningUpdates` "For automatically signed targets, xcodebuild
will create and update profiles, app IDs, and certificates", and that the
three `-authenticationKey…` options (Xcode 13 and later) stand in for an
Xcode account. Both apps are automatically signed, and an Admin key may
register identifiers. Not yet seen on this team's account.

If the archive fails on the Watch app ("No profiles for
'….watchkitapp' were found", or a message that the App ID could not be
registered or is not available), register it by hand once, then run the
archive again: developer.apple.com, Certificates, Identifiers & Profiles,
Identifiers, **+**, App IDs, App, Explicit bundle id
`<PHONE_BUNDLE_ID>.watchkitapp`, no capabilities. Nothing changes in App
Store Connect: the Watch app ships inside the phone app's record, not in one
of its own.

## First, an unsigned check

Before signing anything, check the project builds and carries the Watch app.
No API key, no Apple account, no real values: the ones below are made up and
never leave the Mac. From `ios/` in this checkout:

```shell
bin/generate --spec project.testflight.yml        # makes LanyardTestFlight.xcodeproj (BUILD.md, 2a)
grep -c 'Embed Watch Content' LanyardTestFlight.xcodeproj/project.pbxproj   # 1 or more

xcodebuild build -project LanyardTestFlight.xcodeproj -scheme LanyardPhone \
  -configuration Release -destination generic/platform=iOS \
  -derivedDataPath build/Precheck CODE_SIGNING_ALLOWED=NO \
  PHONE_BUNDLE_ID=org.example.lanyard DEVELOPMENT_TEAM=AAAAAAAAAA \
  LANYARD_BASE_URL=https://example.org MARKETING_VERSION=0.1 CURRENT_PROJECT_VERSION=1

APP=build/Precheck/Build/Products/Release-iphoneos/LanyardPhone.app
test -d "$APP/Watch/LanyardWatch.app" && echo "Watch app inside: good"
# What App Store Connect checks. Phone: org.example.lanyard, UIDeviceFamily 1,
# MinimumOSVersion 17.0. Watch: org.example.lanyard.watchkitapp, WKApplication
# true, WKCompanionAppBundleIdentifier org.example.lanyard, UIDeviceFamily 4,
# MinimumOSVersion 10.0, CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName AppIcon. Both: 0.1 and 1, and
# NSAppTransportSecurity an empty Dict.
show() {
  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion MinimumOSVersion \
      UIDeviceFamily WKApplication WKCompanionAppBundleIdentifier WKWatchKitApp \
      CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName NSAppTransportSecurity; do
    printf '%s: ' "$key"; /usr/libexec/PlistBuddy -c "Print :$key" "$1" 2>/dev/null | tr -s '\n ' ' ' || true; echo
  done
}
show "$APP/Info.plist"; echo; show "$APP/Watch/LanyardWatch.app/Info.plist"
```

`WKWatchKitApp` must print nothing: it marks the old two-part Watch app, and
this one is a single target (`WKApplication`). If the build or a check fails,
report the command and the last 40 lines of its output before going on.

## The commands

From `ios/` in this checkout, in a shell where the variables above are set:

```shell
# Over SSH the login keychain is locked, and signing then fails
# (errSecInternalComponent). Unlock it with your own login password; it prompts.
security unlock-keychain ~/Library/Keychains/login.keychain-db

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")
OUT=build/TestFlight
ARCHIVE="$OUT/LanyardPhone-$MARKETING_VERSION-$BUILD_NUMBER.xcarchive"

bin/generate --spec project.testflight.yml        # makes LanyardTestFlight.xcodeproj (BUILD.md, 2a)

xcodebuild archive -project LanyardTestFlight.xcodeproj -scheme LanyardPhone \
  -configuration Release -destination generic/platform=iOS \
  -derivedDataPath "$OUT/DerivedData" -archivePath "$ARCHIVE" "${AUTH[@]}" \
  PHONE_BUNDLE_ID="$PHONE_BUNDLE_ID" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  LANYARD_BASE_URL="$LANYARD_BASE_URL" \
  MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

# Check the archive: embedded Watch app, right ids, matching version and
# build, and the right address.
PHONE_APP="$ARCHIVE/Products/Applications/LanyardPhone.app"
WATCH_APP="$PHONE_APP/Watch/LanyardWatch.app"
test -d "$WATCH_APP" && echo "Watch app inside: good"
/usr/libexec/PlistBuddy -c Print "$PHONE_APP/Info.plist" \
  | grep -E 'CFBundleIdentifier|CFBundleShortVersionString|CFBundleVersion|LanyardBaseURL|NativeSignInScheme|ITSAppUses'
/usr/libexec/PlistBuddy -c Print "$WATCH_APP/Info.plist" \
  | grep -E 'CFBundleIdentifier|CFBundleShortVersionString|CFBundleVersion|LanyardBaseURL|WKCompanionApp'
for key in CFBundleShortVersionString CFBundleVersion; do
  [ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$PHONE_APP/Info.plist")" = \
    "$(/usr/libexec/PlistBuddy -c "Print :$key" "$WATCH_APP/Info.plist")" ] \
    && echo "$key matches: good" || echo "$key differs: stop"
done

# Signs for distribution into an .ipa (destination "export" in the plist),
# checks that very file's push signing and usage strings, and only then
# uploads it.
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions-testflight.plist -exportPath "$OUT/export" "${AUTH[@]}" || exit 1
IPA="$OUT/export/LanyardPhone.ipa"
bin/check-push-entitlement "$IPA" || exit 1
bin/check-usage-strings "$IPA" || exit 1
xcrun altool --upload-app --type ios --file "$IPA" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH"
```

Why `PHONE_BUNDLE_ID` and not `PRODUCT_BUNDLE_IDENTIFIER`: a setting on the
command line applies to every target, the Swift package's included, and
would give them all the app's bundle id. Only the app reads `PHONE_BUNDLE_ID`.

The export ends with `** EXPORT SUCCEEDED **` and writes the `.ipa`; the
upload is the separate `altool` step after the check. The check reads every
signed target in that `.ipa` (the phone app, the Watch app, any extension)
from its signature with `codesign`, prints each one's entitlements for the
receipt, and stops unless each has `get-task-allow` false, the phone app has
`aps-environment` production, and any other target with push has production
too. `bin/check-usage-strings` then reads the signed phone app's Info.plist in
the same `.ipa` and stops unless `NSCameraUsageDescription` and
`NSMicrophoneUsageDescription` are there and not empty: a file field's Take
Photo or Video runs in the app, and iOS kills an app without them. Since Xcode 26 `altool`
can report a failed upload with exit status 0, so read its output for
`UPLOAD SUCCEEDED` or an error, as well as its status. If the export fails, report the last 40 lines and the `.xcdistributionlogs` folder it
names (`IDEDistributionProvisioning.log` shows signing failures). Do not
retry an upload that may have succeeded: a build number can be used once.

`ExportOptions-testflight.plist` has no `teamID`: the export uses the
archive's team.

## After the upload

Processing takes from a few minutes to about an hour. The simplest check is
App Store Connect: the app, **TestFlight**, then **iOS builds**: the build
appears as Processing, then Ready to Test. The encryption answer is in the
app (`ITSAppUsesNonExemptEncryption` false), so it should not stop at
"Missing Compliance".

Testers: in **Internal Testing**, open a group (or create one with **+**) and
add the testers, who must be users of this App Store Connect team. A group
with automatic distribution gets each new build; otherwise add the build to
the group. Testers install it from Apple's TestFlight app on the iPhone.
The Watch app comes with it. If it does not appear on a paired Watch, open
the Watch app on the iPhone and install Ajent under Available Apps. Not
yet checked on a device.

The same through the App Store Connect API, as a sketch. `ASC_JWT` is a
short-lived token (ES256, signed with the same `.p8`, issuer id as `iss`, key
id as `kid`, audience `appstoreconnect-v1`, at most 20 minutes) made with
whatever tool you trust; `APP_ID` is the app's Apple ID, a number shown in
App Information.

```shell
API=https://api.appstoreconnect.apple.com/v1
H=(-H "Authorization: Bearer $ASC_JWT")
# The build and its processing state: PROCESSING, then VALID.
curl -sg "${H[@]}" "$API/builds?filter[app]=$APP_ID&filter[version]=$BUILD_NUMBER&fields[builds]=version,processingState"
# Internal groups, then add the build (its id from the first answer) to one.
curl -sg "${H[@]}" "$API/betaGroups?filter[app]=$APP_ID&filter[isInternalGroup]=true&fields[betaGroups]=name"
curl -sg "${H[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"data\":[{\"type\":\"builds\",\"id\":\"$BUILD_ID\"}]}" "$API/betaGroups/$GROUP_ID/relationships/builds"
```

## Signing in inside the app

Identity providers, Google above all, refuse to sign anyone in inside an
app's own web view, and passkeys do not work there either. So the app does
not sign in in its web view. It signs in the way providers allow a native app
to: in a browser sheet, Safari's own browser, opened by the app
(`ASWebAuthenticationSession`).

1. The web's sign-in page knows the app (its user agent says
   `NativeSignIn/1`) and shows **Sign in with Ajent** as a link to
   `/native_sign_in/new`. The app catches that link and opens the sheet
   instead, at `/native_sign_in/new?code_challenge=…&code_challenge_method=S256`.
   The challenge is the SHA-256 of a random secret, the verifier, that only
   the app holds (PKCE).
2. iOS asks "Ajent Wants to Use … to Sign In"; the person taps Continue.
   In the sheet, Rails keeps the challenge in that browser's session and goes
   straight on to the provider, as the button does. The person signs in
   there, with Google, a passkey or a password, whatever the provider offers.
3. The provider returns to `/auth/ajent/callback` as always, with the same
   checks (a verified email on the list). Then, instead of starting a session
   in the sheet, Rails sends the sheet to the app's own address,
   `<scheme>://signed-in?code=…`, and the sheet closes. The code is
   encrypted, lasts two minutes and works once.
4. The app posts the code and its verifier to `/native_sign_in` from a web
   view of its own. Rails checks the verifier against the challenge and starts
   the ordinary session, whose cookie lands in WebKit's store, where every
   page of the app and the Watch's token request read it. The app then shows
   the start page. A wrong, expired or reused code signs nobody in; the app
   says "Sign-in did not complete".

Signing out is the web's own Sign out, as before. It signs the app out, not
the provider: the next sign-in may go straight through. The sheet shares
Safari's sign-ins (that is why Google and passkeys work), but it never holds
a session of this app.

### What the install needs

- **The app's scheme.** `NATIVE_SIGN_IN_SCHEME`, a build setting, is the
  app's own URL scheme. By default it is `PHONE_BUNDLE_ID`; set it in
  `Local.xcconfig` or on the command line to choose another.
- **The same scheme on the server**, in lower case:
  `APP__NATIVE_SIGN_IN_SCHEME`. Its default, `org.durableassistants.companion`,
  matches only the simulator build. If the two differ, the sheet never
  returns to the app (it waits until the person closes it).
- Nothing changes at the identity provider: the redirect address is still
  `/auth/ajent/callback`.

Not yet checked on a device: Google and a passkey in the sheet, and the
"Wants to Use" prompt's wording. The simulator walkthrough covers the rest
(BUILD.md, section 7).

## Notifications

The app gets notifications by Apple's push service (`docs/native-app.md`,
"Notifications"). It needs both halves:

1. **The App ID.** In Apple Developer, Identifiers, the phone app's App ID:
   turn on Push Notifications. `TestFlight.xcconfig` names
   `Phone/Push.entitlements`, so the build carries `aps-environment`, and
   automatic signing refuses it for an App ID without the capability. To build
   for one, set `PHONE_ENTITLEMENTS =` (empty) in `Local.xcconfig`; the build
   then has no push.
2. **The key.** In Apple Developer, Keys: make a key with Apple Push
   Notifications service (APNs) and download its `.p8`, which Apple offers only
   once. The install sets `APNS__KEY_ID`, `APNS__TEAM_ID`, `APNS__PRIVATE_KEY`
   (the `.p8` contents) and `APNS__TOPIC` (the phone app's bundle id) in its
   secrets. Rails sends nothing until all four are set.

`bin/check-push-entitlement "$IPA"` reads the exported `.ipa`, the very
file that is uploaded, and the phone app's **signed** entitlements in it with
`codesign`. It passes only on `aps-environment` production and
`get-task-allow` false; anything else, or anything it cannot read, stops the
upload block. The archive's own signing is not checked: only the export is
what a phone installs.

A TestFlight build's tokens are for Apple's production service; a Debug
build's are for its sandbox. The app tells Rails which (`APNs/…` in its user
agent), and Rails sends each token to its own service.

A phone with notifications allowed posts its token to `POST /push/devices`
at each launch and each return to the app, signed in or newly allowed in
iOS Settings. To check a new build on a device: open the app signed in, then
look for that post in the install's log and a `push_devices` row. A signed-in
phone that never sent its token was the gap in build 202611150540.
