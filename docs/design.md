# Design

The interface follows shadcn/ui as a quality bar and a pattern catalogue,
not as code. It's built from plain CSS (`app/assets/stylesheets/tokens.css`
and `components.css`), ERB partials under `app/views/ui`, helpers, Stimulus
and native elements. `/rails/components` shows every shared piece in each
state, in development; a test renders it.

Where a shadcn pattern fights Hotwire or touch screens, the native or Turbo
way wins. Campfire and Fizzy are the references.

## Rules

- **One colour, the accent.** `APP__ACCENT_HUE` (0 to 360, checked at boot),
  or the workspace's own (`docs/deployments.md`, "A workspace's own name,
  colour and link host"), is `--accent-hue` in a style in the head, which
  Turbo swaps when the workspace changes, and `tokens.css` derives every shade from
  it in oklch: `--brand` for the person's bubbles, primary buttons and the
  open agent in the list, and the focus ring. Its lightness is fixed, so
  white text on it passes 4.5:1 at any hue. Everything else is grey. The icon is a
  white bubble on a tile of the accent, as Messages' is on green: `Icon` draws
  it in the install's hue for every size a browser or phone asks for (the
  PNGs from greyscale masks, `bin/rails icons:masks`).
- **The system's faces.** `system-ui` (SF Pro on Apple devices) for the
  interface, `ui-monospace` (SF Mono) for code. No web fonts. The wordmark is
  the icon and the app's name, semibold and a touch tight.
- **Tokens, not values.** Colours, radii, 4px spacing steps (`--space-1` to
  `--space-12`), a type scale that grows a little with the screen
  (`--text-xs` to `--text-xl`) and the measure are custom properties in
  `tokens.css`, named as shadcn names them, light and dark.
  Text passes WCAG AA (4.5:1). A field's edge and the focus ring pass 3:1
  (WCAG 1.4.11). A card's edge (`--border`) only decorates, so it may be faint.
- **Thumb-sized.** On a touch screen, every button and field is at least
  44px tall.
- **Tooltips are native and never essential.** Every icon-only control has
  an `aria-label` and a `title`. The `title` is the tooltip a mouse gets for
  free; touch never sees it, so nothing a person needs lives only there.
  There's no JavaScript tooltip component. `test/system/dialogs_test.rb`
  holds the rule.
- **Dialogs are `<dialog>`.** A confirm (`layouts/_confirm`), help, and the
  agents panel are native dialogs, opened modal. Escape and focus trapping
  come free.
- **Toasts** (`layouts/_flash`) float above the page. A notice goes by
  itself; an alert stays until closed.
- **Errors sit at the field** (`config/initializers/field_errors.rb`).
- **Skeletons go inside the frame.** A lazy or `src` turbo frame holds
  `ui/skeleton` as its placeholder, and Turbo swaps it out on load. A
  connector listing its tools and a computer waking up show the same pulse,
  as do a thread's earlier messages, which keep the reader's place as they
  load above. Nothing moves under `prefers-reduced-motion`.
- **An agent's avatar** (`AvatarsHelper#agent_avatar`) is its initials on one
  of eight colours, chosen by its id. White on each colour passes 4.5:1. It
  is decorative, because the name is always beside it. An uploaded photo
  would replace the drawing in that one helper.
- **The agents list says where each agent stands, live.** A marker beside the
  face: amber "!" needs you, a red triangle stopped on an error, a blue dot an
  unread reply, three dots working (the line under the name says which tool),
  a hollow ring when its computer is off, nothing when idle. They sort by the
  last news for the person: a card that starts waiting on them, or a reply to
  them, moves a row to the top; nothing else moves it. Each change is broadcast
  from the model as that one row on its workspace's list stream; new agents
  arrive in their workspace's group, archived ones leave, and a small
  controller in each group puts a moved row in its place, but not while the pointer, keyboard focus or a scroll is on the list:
  then it waits, applies a second later, and moves rows at most every two
  seconds. A click that ends on another row than it began on opens nothing. A reply that arrives while
  its thread is open and in view is read (`Conversation::Standing`).
- **The agents list on a narrow screen** is the same sidebar partial inside
  a `<dialog>`. On a wide screen the dialog is just the sidebar's column
  (`display: contents`) and is never opened. Narrower, it slides in and out
  by `data-shown` (`panel_controller.js`), so closing animates in Safari too
  before the dialog leaves; Esc, the backdrop, a swipe toward the edge and a
  choice close it, and nothing behind it scrolls while it is open.
- **The sidebar's width is the person's.** Its edge drags it between 14 and
  28rem, the arrow keys move it, and a double-click or Home resets it
  (`sidebar_resize_controller.js`). The width is a cookie, so the page is
  drawn at it from the start rather than jumping once the script runs.
- **A row's time is short**, so the name keeps the room: "now", "4m", "3h",
  "Tue", "Nov 4", "11/4/25", in a fixed width, with the full time in its
  title (`ConversationsHelper#list_time`; `local_time_controller.js` keeps it
  current in the reader's zone).
- **The thread reads as Messages.** The person's words are right-hand
  bubbles in the accent with white text; the agent's are left-hand, in grey.
  Turns on one side with nothing between them are a run: they sit close, and
  only the last has a tail (the bubble's corner running on into a curve that
  hooks out to a point, in its own colour) and the agent's face. The day sits centred
  before each day's first turn ("Today", "Yesterday", "Tuesday", "Nov 2"), and
  a quiet time under the last turn of each run of one sender's turns, each within
  five minutes of the one before; the newest run's says "Just now" or "5 min
  ago". Hover, or a tap on a bubble, shows any turn's full date and time. All of
  it is written in the reader's own zone and words (`thread_times`, with
  `local-time`'s wording), from the time each turn carries. While the agent works before its first word, three dots in
  its bubble (`ui/typing`), which the reply replaces as it streams. A long
  reply keeps to the bubble's width, and its code and tables scroll sideways.
  Code is highlighted by class from the tokens (`ApplicationHelper#markdown`).
- **The status line is quiet until something needs the person.** Above the
  composer, in muted words: the model and effort, "Included in plan" or what
  the thread has cost on an API key, a bar for how full the context is, and
  Concourse's standing. Colour only for action: amber as the context nears its
  summary point or the cache is about to lapse, red when Concourse mail can't
  arrive. Details opens the facts in words: the model, the thread's memory, its
  Concourse mail (`Conversation::StatusLine`, `conversations/_status_line`).
- **A reply's actions stay out of the way.** With a mouse, Copy and New
  agent from here float beside the reply on hover or focus, as icons; on a
  touch screen a tap on the bubble shows them under it (`reveal`). A sent
  message has none: the person corrects it by sending the next one.
- **Copying gives the words alone.** Selecting across bubbles and copying
  leaves out buttons, times, usage lines and bubble colours, as plain text
  and as clean HTML (`clean-copy`). `test/system/thread_look_test.rb` holds it.
- **A Mac's manners.** The agents list is shaped as Messages' list: the face,
  the name and when, one line of the newest words, search at the top, a
  translucent sidebar, and at its foot who is signed in, a Settings gear and
  Sign out. Beside
  the sidebar a thread has no bar of the app's own; the agent's other doings
  (Connectors, the screen, its settings, archiving) are in the thread
  header's ⋯ menu at every width. ⌘N, ⌘F, ⌘1 to ⌘9, ⌘/ and ⌘, (Settings) work anywhere
  (`shortcuts`; Ctrl off a Mac), and the help lists them. A browser keeps
  ⌘N and ⌘1 to ⌘9 for its tabs; the installed app does not. Installed on a
  Mac, beside the sidebar, the title bar is an empty strip to drag the
  window by, beside the window's buttons (`window-controls-overlay`).
- **Send as Messages sends.** A round accent arrow, there only once
  something is typed or attached. While the agent works, the arrow steers it
  (as Enter does), Queue waits for it to finish, and with nothing typed a
  square stops it. Each is drawn inside a thumb-sized target. The box says
  "Message <agent>", or just "Message" where that would wrap. While the agent
  works the thread's header says nothing: the dots and the square say it. The
  header speaks only when the person is needed (waiting on them, with Stop)
  or a run stopped, with why. A message sent while the agent works waits
  under its reply, as pi shows it, saying "Steering" or "Queued" and when the
  agent reads it, marked "You", with Steer instead (or Queue instead), Send
  now, move up and down, Edit (back into the box) and Withdraw until the
  agent takes it in. Someone else's message waits as one line, sender,
  channel and its first line, that opens to the whole of it as in the
  thread, with the same controls but Edit and Withdraw (it is answered,
  never dropped): Concourse mail's Markdown rendered and sanitized as a reply's is (`messages/_incoming_body`), an email or a text
  as it was typed. While a card waits on the person, a "Needs you" bar sits
  just above the box, naming the oldest card (and how many more) and linking
  to that card's own page (`/approvals/:id`), which loads it alone with every
  choice it has, a question's answer form and a sign-in's too, however far
  back in the thread it was asked; so the card is never lost above a growing
  queue or beyond the loaded page. A steer then says the agent reads it after
  the card is answered, and the thread stays waiting, without the typing
  dots, whatever else arrives.
- **Waiting and working are two facts.** Whether the agent's own run goes
  (`execution_status`: idle, running, error, or unknown) comes from the
  sidecar's frames and snapshot and from a send accepted for the first time;
  whether a card waits on the person comes from the ledger. The thread shows
  one status from both (`Conversation::Activity`): an unexpired card wins as
  waiting, otherwise the run says. A background helper's card can outlive
  the run, so the run ending never clears it, and answering the last card
  shows the run as it is, idle if it ended meanwhile, never invented work.
  A run Rails can't vouch for (a thread that was waiting when runs were first
  recorded) says "Checking run status" until the sidecar is next asked, at
  the page load or the minute's sweep.
- **A helper is one line.** "Helper: <its task>" with how many calls it made;
  its calls fold into the line, each opening to what it was given and what
  came back, and settle to done or failed when it answers. A call waiting on
  the person shows even when the line is closed. A helper in the background
  says where it stands on the same line ("Helper working on: <task>", then
  finished, stopped, cancelled, or "didn't start" when the limit refused it),
  with "Cancel helper" while it works (its confirm's Cancel reads "Keep working")
  and, once cancelled, what it had already done in words, its dot grey; why
  one stopped is said in words, not the sidecar's code. Its answer arrives as
  a message of its own, and the status line counts helpers working. A card it
  raises says it came from a helper.
- **Motion is quick and optional.** View transitions between pages (a page
  refreshed in place just changes: a cross-fade would show the old and new
  lists over each other), a sent message and the dots rising in
  (`@starting-style`), Thought process opening smoothly (`interpolate-size`),
  and the thread's header lifting as messages scroll under it (a scroll
  timeline). Each takes `--duration`
  (180ms); under `prefers-reduced-motion` none of them moves.
- **Installable.** The manifest has the icon at 192 and 512, a maskable one,
  pictures of the app for the install sheet, wide and narrow, in a graphite
  accent so they suit every install (taken by
  `test/system/install_screenshots_test.rb`; `SCREENSHOTS=1` takes them
  again), a New agent shortcut and the title-bar overlay; the service worker serves a small offline page when a
  page cannot load, and never a stale thread. Safe areas pad the header,
  composer and panel.
- **Settings are a Mac's System Settings** (`layouts/settings`). On a wide
  screen, a translucent sidebar of places (You, Notifications, Apple Watch,
  Models, Connectors, Helpers, then each
  agent with its sections: General, Instructions, Tools, Skills, Commands,
  Routines, Permissions, Computer, Channels) and the open one beside it.
  As beside a thread, there is no bar of the app's own above them: the
  sidebar's first row, "‹ Agents", goes back to the open agent's thread (the
  installed app keeps its strip to drag the window by). On a
  phone, one level at a time as iOS Settings: `/settings` is the list, a
  place slides in from the right, and the header's way back goes up a level
  (Turbo's visit direction; `data-going-up` for a link that goes up). Each
  page is grouped, inset rows (`ui-group`, `ui-row`): a label and a line
  about it on the left, the value or control on the right, one line of help
  under the group. A row that drills in ends in a chevron. A row with a
  menu or a field keeps one line at any width, as iOS's do: the value
  shrinks to an ellipsis rather than wrapping under its label, and on a
  phone a field sits right-aligned and borderless until it is focused.
- **A small setting saves as it changes; long text has Save.** A switch
  (`ui-switch`, a native checkbox with `role="switch"`, its whole row's label
  the thumb's target) or a menu submits on change (`autosave`), the page
  morphs in place, and "✓ Saved" appears and fades. Instructions, a skill and
  a command have an explicit Save, and leaving with changes unsaved asks in
  the confirm dialog (`unsaved`). Removing anything confirms with its name.
- **A status is a word and a colour** (`ui/status`): Connected, Needs
  sign-in, Error, Off. Never the colour alone, and never without the action
  that fixes it (`connectors/fix`).
- **An agent's Tools are one list.** A meter ("38 of 64 tools", `ui-meter`)
  counts what the next message carries, warns from 56, and names the
  connector to switch to "Looked up when needed". Below it, a search field
  filters every tool in place (`search-list`), grouped Built in, each
  connector, Skills, each with a switch for this agent alone. A connector's
  own page switches a tool off for every agent. A connector that needs
  sign-in offers its tools to no agent, and the meter leaves them out; both
  pages still list them, greyed, their switches disabled, saying "Needs
  sign-in" beside the Sign in that brings them back.
- **A place has a tile.** Settings' places are a small white icon on a
  coloured tile (`ui-tile`, `AvatarsHelper#settings_tile`); a connector, its
  initial on one (`connector_tile`); a person and an agent, their avatar.
- **Screens say "agent".** Never conversation, assistant, topic or bot.
- **Plain CSS, not Tailwind.** 37signals' own apps use plain CSS with custom
  properties, as this one does. A switch would be a rewrite nobody would
  feel.

## Canvas

A document the agent writes (`write_document`, `edit_document`) shows in
the thread as a card: its name, its kind, and Open. Open fills the thread's
canvas frame, a Turbo Frame beside the messages on a wide screen (a third
column, from 960px) and a full-screen sheet over them on a phone; the frame
stays open as the page morphs, and Done empties it. Done is its own one-job
controller (`canvas-done`), the seam a native app's Done replaces. On its own
address the canvas is a page, with Done going back to the thread.

- **Documents, New document, Recently deleted.** The thread's More menu has
  Documents: every document of the agent's, newest first, with its kind,
  size and when it last changed. New document takes a title and its words,
  in the same plain box, as the person's first version, which the agent sees
  with their next message. View has Delete, which asks once: a deletion is
  soft (`Document::Deletable`, `resource :deletion`), so the document leaves
  every list, read and tool, and Recently deleted lists it, saying who
  deleted it and until when, with Restore (`resource :restoration`) for 30
  days. Restoring takes its title back, or "Title (2)" if a document has it
  since. Every day `DocumentPurgeJob` removes those deleted longer ago, with
  their versions. The agent does the same with `list_documents` and
  `delete_document`, neither asking first: the owner judged 30 days to
  restore, and the call in the thread's ledger, enough. Who deleted it, the
  agent or the person, is kept on the document beside when; a deletion is
  not a version, since a version is the document's words, and one would show
  the agent a change that is not there.

- **View, Edit, History** are three radios drawn as one segmented control;
  the checked one's pane shows (`:has`), with no JavaScript. View renders
  Markdown with the app's renderer and code with its highlighter, with Copy
  (the exact source) and Download (named for its kind). History loads when
  first shown, newest first, saying who wrote each version and when
  (`local-time`); Restore makes an old version the newest again, as the
  person's.
- **One plain box.** Edit is a `<textarea>` that grows with its text
  (`field-sizing`), monospaced for code, with Save and the settings' warning
  before unsaved words are lost (`unsaved`, which Done asks too). No editor
  library: the browser's box already undoes, finds and spell-checks, a
  phone's keyboard knows it, and a native app gets it free. Save sends the
  version it began from; if the agent wrote one since, the person's words
  stay in the box and View shows the agent's, so nothing is overwritten
  unseen.
- **What the agent writes arrives live.** A new version replaces the
  canvas's View alone, never the box being typed in.
- **The agent sees the person's edits as a diff.** Their next message
  carries, after their words, a unified diff of each document they changed
  since the agent last saw it (`Document.changes_for_agent`), inside the
  sidecar's limit; the bubble shows only their words and "With your edits to
  the canvas". Reading or writing a document counts as seeing it.
- **No HTML or SVG preview.** The brief allowed one only if it provably
  reached no network. In an `<iframe sandbox="allow-scripts" srcdoc>` with a
  `default-src 'none'` policy first, `fetch()` and pictures were blocked, but
  the page could still navigate itself and its meta refresh worked (no
  browser enforces `navigate-to`), and an `RTCPeerConnection` reached a STUN
  server (Chromium ignores `webrtc 'block'`). A page or an SVG is therefore
  code, shown as its escaped source.
- **Loaded with the canvas.** `canvas.css` and `canvas.js` come inside the
  canvas, so a thread's first load (its budget test) does not carry them.

## Notifications, badge and sharing

The installed app tells the person when an agent needs them, counts on its
icon how many do, and takes what other apps share.

- **Rails decides when to notify** (`Conversation::Notifiable`). An agent
  **needs you**: a card starts waiting on the person (an approval, a
  question, a sign-in), titled "Iris needs you" with the card's own title
  ("Allow send email?"). An agent **finished a reply**: a run ends idle with
  the agent's answer as its newest turn, titled with the agent's name and the
  reply's first 120 characters as plain text. An agent **stopped with an
  error**, as the thread shows it: titled with the agent's name, said from the
  kind of failure (`Conversation::Failure`), never the failure's own text,
  which may hold anything; a kind the app has no words for says only that it
  stopped. Once until something goes right (`error_told_at`): runs that fail
  again before a run ends well or the person writes, started by mail, a
  routine or another agent, are not told again. Agents paused in a Campfire room and an agent's texts paused for
  the day are told too. Never a streamed word, the person's own message, or a
  routine's run that ended without a word to the person.
- **One gate, and the person's choices.** Every notice goes through
  `Push.deliver`, which sends it only where the install has keys, the person
  has a device, and they want its kind. Notifications has three switches, all on until
  turned off: Messages (replies), Needs you (cards, a paused room) and Errors
  (a stopped run, paused texts).
- **Two levels** (#82). A card waiting on the person (`needs_you`: an
  approval, a question, a sign-in, a bridge to approve) is **priority**: on
  the phone it sounds, reaches the Watch and is `time-sensitive`, so it comes
  through a Focus; Apple is asked to send it at once (`apns-priority` 10), a
  browser's push service as `high`. Everything else (replies, errors, a paused
  room, paused texts) is **regular**: `passive`, with no sound and no banner,
  so it goes only to Notification Centre, grouped by its thread
  (`thread-id`), sent when it suits the battery (`apns-priority` 5, Web Push
  `normal`), shown silently in a browser. `Push.level` decides from the
  notice's kind and the agent it is from; nothing raises a regular kind, and
  no tool chooses. The owner of the agent's workspace can lower its cards to
  regular on its General page ("Priority", `Agent#priority_notifications`, on
  until turned off); another member sees the switch read-only, and the app
  refuses her change (`Agents::PriorityNotificationsController`).
- **No device, then email, for "needs you" only.** A person who has turned
  notifications on nowhere gets the same title and card title by email, from
  the agent's address, with a link back to the thread, where the install has
  email (`AgentMailer#needs_you`). An agent waiting on someone is never
  waiting unseen. Finished replies are not mailed: that would be every reply.
- **A notice holds** `{ kind, level, title, body, url, tag, badge }`: the thread's
  address, one tag per thread so a newer notice replaces an older, and the
  badge's count. For the phone's and the Watch's buttons it also holds
  `conversation_id`, and for a card `invocation_id`, its `category` and the
  card's `version` (a digest): "A notice's buttons", below. Web Push encrypts it end to end, but it lands on a lock
  screen, so it carries only the agent's name, a card's title and a reply's
  opening words: never a tool's arguments, a secret or an email's body
  (a question's card is its question, the agent's words to the person).
  `Push::DeliveryJob` sends it to each of the person's devices with the
  `web-push` gem; a push service's 404 or 410 deletes that device, and any
  other failure is logged and the device kept. The server posts only to the
  browsers' own push services (`Push::Subscription::PUSH_SERVICES`).
- **Every push shows a notification.** iOS takes a subscription away after a
  few pushes that show none, so the service worker shows one for each, even
  an empty or broken push ("New activity", opening the app).
- **The focus rule is the device's.** A reply's notice to a focused window
  already on that thread is shown silently and closed at once: only the
  device knows which window is in front. A "needs you" notice always shows,
  since the card may be out of view. A click focuses the window already on
  the thread, else moves the app's open window there, else opens one.
- **Asked from Settings, never on load.** Notifications has "Notifications on this
  device": the switch asks the browser for permission from its own click,
  subscribes with the install's public key and posts the address; off
  unsubscribes and deletes it. The row says what the browser says: on, off,
  blocked in the browser's settings, or not supported. On an iPhone or iPad,
  Web Push exists only in an app added to the Home Screen, so outside one the
  row says to add it there first. Below it, the person's devices ("Robin's
  devices": the browser and system, when added, This device) each with
  Remove. On, "Send test notification" pushes to this device now, through the
  same sender, and says what its push service answered: sent, expired (the
  device removed) or failed with its HTTP status. Without the install's keys,
  or with a subject other than a `mailto:` or `https:` address (Apple refuses
  any other), push is off and the row says the app isn't set up for it yet.
- **The badge** is the number of cards waiting on the person in all their
  workspaces, the cards Needs you lists (`User#needs_you`). Every page renders
  it (`layouts/_badge`, the `badge` controller sets `navigator.setAppBadge`)
  and Rails re-broadcasts it whenever a card starts or stops waiting; a notice carries it for the
  service worker to set. Where there is no Badging API nothing happens.
- **The Share sheet** (the manifest's `share_target`) posts words, a link and
  pictures to `/shares`. The operating system's post carries no CSRF token,
  so it is accepted only with `Sec-Fetch-Site: none`, which only a navigation
  the person started outside any page has and no page can forge; any other
  post is checked as every form is, and another site's is refused. Signed
  out, it goes to sign-in and asks the person to share again: its pictures
  came with that one request. A share sends nothing: with one agent it opens
  that agent's composer, otherwise "Share with…" lists the agents; the
  composer opens with the words in the box and the pictures attached through
  its own attachments controller and limits, and the person presses Send.
  Files the composer could not send (not a picture, over 5 MB, past four)
  are refused at the door, each by name. A share is a record of the person's
  (`Share`), since a blob has no owner; sending the message deletes it, and
  `ShareSweepJob` deletes any unsent after a day.
- **Loaded where used.** The notifications row's script (`settings.js`) loads
  on its page, a share's (`share.js`) on a composer holding one, and the
  picker's stylesheet on the picker, so a thread's first load stays within
  its budget.

## On a phone, and in many tabs

The app is used on the road, so what crosses the connection is kept small,
and every tab and device shows the same thing without reloading.

- **A streaming reply sends what changed.** The sidecar sends Rails a frame
  five times a second. A frame that follows one Rails took says how much of the
  reply was in it, and the page gets only the Markdown blocks that settled
  since (a blank line ends one) and the block still being written
  (`LiveText`, `conversations/_live_frame`). The whole reply goes every two
  seconds, and whenever it changes shape (the answer begins, a new turn), so a
  tab that missed a frame or opened mid-reply is whole again within two
  seconds. A typical reply with thinking, about 1.4 KB of text at Opus's pace,
  went from 137 KB over the cable to 32 KB; one four times as long from 693 KB
  to 105 KB. Action Cable doesn't compress, and escapes `<` and `>` as six
  bytes each, so markup is what costs.
- **Tabs stay in sync with page refreshes.** A conversation's page listens to
  the conversation, so messages, cards, approvals and the status reach every
  tab. Every page of an agent's settings listens to the agent, which, with each
  of its parts (notes, skills, prompts, routines, documents, its computer,
  bot, permissions), broadcasts a refresh when it changes
  (`broadcasts_refreshes`). The other tabs morph in place; the tab that made
  the change ignores its own.
- **A long thread loads its newest 40 turns** (`Conversation::Page`); earlier
  pages load as the person scrolls up.
- **Assets are fingerprinted** and cached for a year at Cloudflare, which
  compresses them and every page.

## Typing survives

Nothing the app redraws may take away what a person is typing. The thread and
the settings refresh by morphing the page (`turbo_refreshes_with method:
:morph`): an answered card redirects back, a connector's change refreshes every
conversation page, and an agent's work refreshes its settings. A morph sets
every box to what the server rendered, which is empty or old. The morph still
runs, so what the server renders inside the composer stays current (the `/`
list's prompts and skills, the models, the agent's name), and three rules keep
the typing:

- **The text box being typed in keeps its words** on any page that morphs
  (`application.js`, Idiomorph's `ignoreActiveValue`, which Turbo leaves off).
  Text boxes only: a one-line field sends on Enter while still focused and
  should empty when its page comes back. A one-line field that a live page
  morphs under (a helper's Message, in the Helpers panel) is kept by its own
  controller (`settings/keeps_typing_controller.js`), and its form empties
  once it sends.
- **The composer comes back as it was** after a morph (`turbo:morph`): a box
  that wasn't focused is refilled from its draft, which `composer_controller`
  keeps per conversation in localStorage until sent, and resized; the pictures
  picked, which live in `attachments_controller`, are drawn again.
- **A refresh is not leaving.** A form with unsaved changes skips a refresh of
  its own page instead of asking "Leave without saving?" (`unsaved_controller`);
  the page catches up after Save. A link clicked to the same page still asks.

The iPhone app shows the same pages in a web view, so the same rules hold
there. `test/system/keeps_typing_test.rb` types, streams and refreshes.

## On an iPhone

The phone is iOS first; Android gets what the web gives it. The system's own
face, safe areas, 44-point targets and dark mode were already there; a phone
also gets iOS's shapes:

- **A thread has one bar**, as Messages does: Agents on the left in the
  accent, the agent's face over its name in the middle, ⋯ on the right, and
  why it waits or stopped across the foot. On a phone Agents goes back to the
  list, one screen as Messages has; between a phone and the sidebar's width
  (an iPad upright) it slides the list in from the left as a panel.
- **A thread on a phone is the page itself**, not a box scrolling inside it:
  the bar sticks to the top and the composer to the bottom, and iOS's own
  gestures work on the thread as on any page (selecting text and dragging its
  handles, scrolling). Wider, the thread scrolls beside the list in its own
  column. Jump to latest floats just above the status line and the composer,
  never over them.
- **The ⋯ menu is an action sheet**: glass, up from the bottom, a full-width
  row each.
- **The list of agents** has no bar of the app's own: a large title with
  Settings beside it, sort and filter as two quiet menus under it, and rows
  edge to edge with a hairline from the name on. What a thumb reaches for is
  at the foot, where a thumb reaches: the search in a glass capsule and New
  agent a round accent button beside it, floating over the list. Archive
  lives in each agent's ⋯ menu and Connectors in Settings, so a row is one
  target.
- **A way back is a chevron and where it goes, in the accent**
  (`.app-header__back`, marked `data-up`), and Sign out is in Settings, under
  You. The bar is glass and has no edge until the page scrolls under it (a
  scroll timeline).
- **A phone is a stack of screens.** Below the sidebar's width a page opened
  slides in from the right over the one it leaves; a way back, or history's
  back, slides it off again (view transitions, by Turbo's visit direction and
  `data-going-up`).
- **Settings are iOS's grouped lists**: a grey page, each group a white card
  (in the dark, a card lifted off black), small capital headings, a large
  title close under the bar, and "Saved" said in the bar.
- **A form's one action is a wide button**, a quiet button that asks before
  it takes something away is red, and a confirm is iOS's alert: centred, its
  two answers side by side, or one above the other on a phone when one is too
  long to share the line. Its accept reads as the button pressed; its
  Cancel reads as `data-confirm-dismiss` says where "Cancel" would read alike
  ("Keep the card" beside "Cancel the card"). Whatever is pressed gives a
  little.
- **A reply's Copy is Share** where the device can share and is touched
  (`clipboard_controller`): the system's share sheet, which has Copy too.
  iOS doesn't let a web app receive a share from other apps (it ignores the
  manifest's `share_target`); that takes a native app (Native, below).

## Joining Concourse

An agent joins Concourse, the agents' mail network the install names
(`CONCOURSE__ORIGIN`), in one click from its Channels settings, by a contract
agreed with Concourse. Concourse and Campfire sit side by side there, one card
each, stacked on a phone. The code is in `ConcourseAgent::Join` and
`DurableAssistants::Concourse::Connect`; the tests run against a stand-in
(`test/test_helpers/fake_concourse.rb`).

- **The flow.** Join Concourse sends the browser to `<origin>/connect` with a
  `state`, a PKCE S256 challenge, a handle made from the agent's name, its
  name and the install's. The person signs in there, picks an organization,
  may change the handle, and approves. Concourse sends them back to
  `/concourse/callback` with a one-time code, which Rails redeems within ten
  minutes at `/connect/token` for the agent's address and its own machine
  client, kept encrypted on its `ConcourseAgent` as a pasted one was. The
  address is its A2A URL, `<origin>/a2a/<organization>/<prefix>/<handle>`;
  one on another origin, or not agreeing with the organization and handle
  beside it, is refused, and `prefix/handle` (`acme/iris`) is kept. A
  credential received but not kept, for a bad shape or a failed save, is
  retired at `/connect/revoke` with that credential, so no agent is left on
  Concourse whose secret nobody holds; a Concourse naming another token
  server gets nothing, the address logged for an owner to retire. Joining
  again keeps the old record until the new one is in hand, and retires a
  declined or waiting one then. A code not collected within ten minutes
  retires the agent at Concourse, so the page says to finish in time. The join in progress (state, verifier, agent, when) is in the
  person's session, one at a time; a callback that does not match it, or
  comes after ten minutes, changes nothing. A Concourse that names a token
  server other than `CONCOURSE__TOKEN_URL` is refused.
- **The states**, each one sentence and one action: Not joined (Join
  Concourse), Waiting for approval by an owner of the organization
  (Disconnect), Connected with its address (Disconnect), Declined and
  Disconnected, when Concourse no longer accepts its credentials (both Join
  again, which forgets the old credential first). A connected agent that
  cannot reach Concourse shows Error and why. Only a connected agent reads
  mail, is rung for it or has the `concourse_` tools.
- **Reading mail.** A ring from Concourse wakes one read of the agent's
  event log. Under it, a sweep reads the inbox for anything a lost ring
  missed: every five minutes for an agent Concourse rings for, every minute
  for one it can't ring (a listener reads its log instead). A declined or
  disconnected agent is not swept.
- **Several networks.** Concourse's page is where the organization is
  picked, so which one is known only when the person comes back. A new one
  adds an identity beside the others; one where the agent was declined or
  disconnected is replaced in place, keeping its tasks and push address; one
  where it is already on Concourse changes nothing, and the credential just
  made is retired. Channels shows one block per network, each with its own
  state and Disconnect, then Join another network; with one network it reads
  as before, apart from that button. Each task is tagged with its identity,
  a blank tag (every task from before networks) meaning the first; a
  disconnected identity's tasks keep its id, so none moves to another
  network, and they drop off the task list and the status line's count,
  since nothing can answer them now. A reply always goes through the task's identity; a new
  `concourse_send` must name its network once the agent has two, and is
  refused before anyone is asked if it doesn't. Only then does the agent's
  identity list its networks, and the task list and status line name a
  network.
- **Home network and bridges.** A workspace's owner may name its home
  organization on the workspace's page. A join anywhere else is a bridge
  (`ConcourseAgent::Bridge`): one a member makes shows "Waiting for <owner>
  to approve this bridge", reads and sends nothing and gives no `concourse_`
  tools until the owner presses "Approve the bridge to <network>" on the
  Channels page, which records who and when and is logged; the owner's own
  join is approved at once. Each `concourse_send` onto a bridge asks a
  person, with no "Always", whatever the install approves. With no home
  named, every join is as before (`docs/design/workspaces.md`, 2.3).
- **Asking the agent.** Switched on in its Tools, `join_concourse` answers
  "join Concourse" with a link to `/agents/:id/concourse_join/new`, "Join
  Concourse as <name>" and the same one button; once joined, it gives the
  address and its state instead. `make_agent` offers the same link for the
  agent it made. Leaving for Concourse stays the person's click.
- **Polling.** `GET /api/identity` says where the agent stands. A waiting
  agent is asked again at most once a minute, when its Channels page opens
  or by the minute's sweep. A sweep Concourse refuses asks too, so a
  connected agent an owner removes, or Concourse retires, shows it.
- **Disconnect** asks first ("Its address stops working; joining again
  gives it a new one"), stops the pushes, then has Concourse retire the
  agent (`POST /connect/revoke` with the agent's own token). 204, or the 401
  a repeat gets, is done and the credential is forgotten; anything else
  keeps it and says why, to try again.
- Agents connected before joining existed, with a client the operator bound
  and the owner pasted, are admitted and work as before. The paste form is
  gone.

## When Concourse is slow to answer

Concourse can take a message and give no answer before the app stops
waiting (20 seconds); the call then failed saying it "may have been
delivered", and the agent could send the same words again as a new message
(#86). So each `concourse_send`, new or on a task, is recorded with a key of
its own (`Dispatch`, as texts are, `docs/phone.md`) before Concourse is asked,
under the messageId that names the call. If the answer doesn't come, or
comes in a shape not understood, the app asks the organization's network
agent for that messageId's receipt (the `delivery` query the Pi connector's
reconcile asks; it sends the recipient nothing):

- **A receipt:** it went. Its task is linked to the conversation, as if
  Concourse had answered, so the peer's answer reaches the agent.
- **No receipt yet, or Concourse can't be asked:** the call ends "unknown",
  with the key, and the agent is told not to send it again. The app asks in
  the background, two minutes on and then less often, up to an hour apart,
  and tells the agent once it finds a receipt: it went, with its task. No
  receipt an hour on, or Concourse not to be asked for a day, is never
  called "not sent": Concourse says a missing receipt is no proof, and "not
  sent" would invite a second message. It stays unknown, the agent told not
  to send it again, and its card in the thread says so with **It went** and
  **It didn't go**, for a person who checked Concourse's website or with
  the recipient's owner (`docs/phone.md` has the card).
- **Refused (4xx):** nothing went, and the call fails saying so.

A message goes at most once: a replay of the call sends nothing and asks
for the receipt instead, and the same words to the same agent on the same
task are refused, naming the first, while it is being checked or went in
the last 10 minutes, or while it is unknown. Replies (`concourse_reply`) are not covered yet: a
reply carries no id of its own to look up, so one whose answer never came
still fails saying it may have been recorded, and the agent reads the task
with `concourse_get` first.

## One conversation, one agent

Agents are long-running staff, not threads made on a whim, so a thread is
one agent and branches are no longer offered (2026-11-07): no "Branch from
here", no Branches page, no `/branch` or `/tree`, no "With branches" filter,
no renaming a branch. Editing a sent message went with them, since it made a
branch; the person corrects by sending the next message.

**New agent from here** takes their place. On a finished reply, and in the
thread's ⋯ menu (from its newest reply), it opens New agent with one line
saying what it copies. Starting it makes a whole agent: its own name,
address, computer and Campfire bot, the source's instructions, skills and
notes (the notes file on its computer stays behind, as the computer does),
and a thread that starts as a copy of the source's up to that reply. Its
model, tools and connectors are a new agent's. The sidecar forks the thread
into the new agent's scope (`into` on a fork, `docs/design/CONTRACT.md`) in
the same transaction that makes the agent, so a failure leaves nothing.

Branches already made are left alone: their rows, columns (`parent_id`,
`root_id`, `branches_count`, `forked_at_entry_id`) and pages stay, and a
branch's address still opens it. Dropping those columns may be proposed
later; not now.

## Private by default

An install is one person's own, so it asks never to be found: `robots.txt`
disallows everything, every response carries `X-Robots-Tag: noindex,
nofollow`, every page a `robots` meta saying the same, and there is no
sitemap. Each page's title is its subject, then the app's name.

## Native

The web app is ready for Hotwire Native apps. `ios/` holds the first: an
iPhone shell and its Watch companion, built for simulators so far
(`ios/BUILD.md`). The seams:

- `GET /configurations/ios_v1.json` and `android_v1.json` serve the path
  configuration: forms and the screen open as a modal, the thread has no
  pull-to-refresh. They are open routes (`docs/open-routes.md`).
- A page shown by a native app has `data-native-app` on `<html>`
  (`hotwire_native_app?`), and the web's own header steps aside for the app's
  bar.
- Behaviour lives in small Stimulus controllers that each do one job, so a
  native bridge component can replace one without the others noticing.

### Signing in on the phone

Identity providers, Google first, refuse to sign anyone in inside an app's
web view, so the iPhone app signs in in a browser sheet
(`ASWebAuthenticationSession`, Safari's own browser) and brings the result
back, as OAuth does for native apps (PKCE, RFC 7636 and RFC 8252).
`NativeSignIn` holds the rules; `ios/TESTFLIGHT.md`, "Signing in inside the
app", walks through it.

- The sign-in page shows the app (its user agent says `NativeSignIn/1`) a
  link to `/native_sign_in/new`, which the app opens in the sheet with the
  S256 challenge of a verifier only it holds. That page keeps the challenge
  in the sheet's session for ten minutes and goes on to the ordinary
  sign-in, `POST /auth/ajent`, with OmniAuth's forgery check as always.
- The callback checks the person as always. With a challenge waiting, it
  starts no session in the sheet: it sends the sheet to
  `<APP__NATIVE_SIGN_IN_SCHEME>://signed-in?code=…`. The code is encrypted
  (who signed in, the email, the challenge), lasts two minutes and is spent
  by its first try, which writes its id to the cache (Solid Cache); a second
  write of the same id fails. No table.
- The app posts the code and verifier to `POST /native_sign_in` from a web
  view of its own. A verifier whose SHA-256 is the challenge, for a person
  still on the list, starts the ordinary session (`start_session_for`), so
  the cookie, sign-out and the Watch's token work as for any session.
  Anything else gets a page saying sign-in did not complete, and no session.
- That post has no authenticity token: the app has no page of ours before
  it. The verifier stands in for one, since no other site can know it. A
  post a browser marks as from another site (`Sec-Fetch-Site`) is refused
  anyway, so no page can sign a visitor in as someone else.

### The Watch, with its own token

The Watch app (`ios/Watch`) calls Rails itself, over the network, with a
token of its own: one per Watch (`Watch`), revocable, kept in Rails only as
its SHA-256. The phone never relays a request, and no cookie leaves it.

- **Getting a token.** A Watch without one asks the iPhone app, over
  WatchConnectivity (`transferUserInfo`), which delivers it when the phone's
  app next runs. The phone, signed in, posts `POST /watches.json` with the
  Watch's `name` over its own web session, sending `Sec-Fetch-Site:
  same-origin` as a page would (Rails' forgery check asks for it over https),
  and gets `201 { id, token }`, the only time the token is shown. It hands
  the token to the Watch once, again with `transferUserInfo`. WatchConnectivity
  carries nothing else. The Watch keeps the token in its own keychain (a
  generic password, readable after first unlock, this device only).
- **Using it.** Each request carries `Authorization: Bearer <token>` and
  `Accept: application/json`. A token opens exactly the four actions below,
  as JSON, and starts no session; it needs no forgery check, since no browser
  sends it by itself. Anywhere else it is no one, as any other header is.
  Each use marks the Watch's last use (at most once a minute).
- **Revoking.** Settings, Apple Watch, lists the person's Watches with when each was
  last used, and Revoke, or says none is connected and how to connect one. A revoked or unknown token gets 401; so does one
  whose person has left the list. The Watch then forgets its token, says
  "Open Lanyard on your iPhone to reconnect" and asks the phone again: a
  Watch still paired with the person's iPhone gets a new token when the
  iPhone app opens.
- **Failing closed.** A request waits at most 20 seconds. Nothing shows as
  done until Rails says so; nothing is queued or sent again by itself.

The four actions are the ones the pages use (list, read a thread, answer a
card, send):

- `GET /conversations.json`: the person's agents (`conversation_id`, `name`)
  and the calls waiting for their approval, each an `Invocation::Card`:
  agent, title, recipients, every field whole, `version` and `small`.
- `GET /conversations/:id/messages.json`, optionally `?before=<entry>`: the
  thread's newest 20 turns, the person's messages and the agent's replies,
  each as plain words (`Conversation::Transcript`): `{ conversation_id, agent,
  messages: [{ id, role, text, at }], earlier }`. Never a tool's result or a
  link's address. `earlier` is the `before` of the page above, or null at the
  start. Found in any of the person's workspaces, like the list; reading it
  leaves the thread unread.
- `POST /conversations/:id/invocations/:id/approval.json` with `decision`
  (`approve` or `deny`) and the card's `version`. Allowing a card that changed
  since is refused (409, `changed`); declining it is not, since declining is
  always safe. Allowing one too long for the Watch is refused too
  (`phone_only`) or one already answered or expired (`answered_or_expired`).
  The same answer again from the same person is that answer, already made.
  The Watch never offers Always.
- `POST /conversations/:id/submissions.json` with `content` and a
  `request_id`: 202 means the agent's server accepted the message, not that
  it replied. The same id again is the same message.
- Without a session or a token, or once an email leaves the list, JSON gets
  401, never a sign-in page.

#### A notice's buttons (#78)

A notice to the phone names its buttons by category, and carries the ids and
the card's version an answer needs (`Conversation::Notifiable::Buttons`,
`Push::Device`): `aps.category`, then `conversation_id`, `invocation_id` and
`version` beside `url`. Ids and a digest, never a card's words.

| Category | When | Buttons |
|---|---|---|
| `APPROVAL` | a small approval card (`Invocation::Card#small?`) | Allow once, Decline |
| `NEEDS_YOU` | any other approval card | Decline |
| `REPLY` | an agent's finished reply | Reply, with words (dictation, Scribble) |
| none | a question, a sign-in, a payment, an error | a tap opens it |

The buttons are the Watch's card and composer, nothing more: the phone and
the Watch post the same JSON as above, the Watch with its token, the phone
with its session. So Allow once is checked against the version as for any
card (409 `changed` if it moved since the notice left, say once an email's
preview arrived), while Decline always declines,
a long card is never allowed from a notice (`phone_only`), and Always is
never offered. A reply goes under `request_id` `notice-<the notification's
id>`, so the same tap delivered twice is one message. Nothing is queued: an
answer that fails says so in a new notice, and the card waits.

A tap opens the right place: on the phone the notice's `url` (the card, or the
thread); on the Watch the card by `invocation_id`, else the thread by
`conversation_id`. Not yet checked on a device: a notice forwarded to the
Watch, its buttons there and dictation.
