# How a Hotwire Native app shows each address (docs/native-app.md): which
# open as a sheet over the page beneath, which push onto the stack, and where
# pull-to-refresh is on. The apps read it at launch, before anyone signs in:
# rules, nothing about anyone. A version is fixed once a build reading it has
# shipped; new behaviour is a new version, so an older build keeps the rules it
# was written for. The phone app bundles its version's copy for a launch with
# no network (ios/Phone/path-configuration.json), the same as this.
class PathConfiguration
  SHEET = { context: "modal", modal_style: "large", pull_to_refresh_enabled: false }.freeze

  V1 = [
    { patterns: [ ".*" ], properties: { context: "default", pull_to_refresh_enabled: true } },
    # Forms and the screen: a modal, closed by Done, not a page in the stack.
    { patterns: [ "/new$", "/edit$", "/screen$" ], properties: { context: "modal", pull_to_refresh_enabled: false } },
    # A thread scrolls to its end and loads earlier messages as it is pulled down.
    { patterns: [ "/conversations/\\d+$" ], properties: { pull_to_refresh_enabled: false } }
  ].freeze

  # The phone app with its tabs (Agents, Needs you, Settings). Everything not
  # named here pushes, and refreshes when pulled: the lists and the threads.
  V2 = [
    { patterns: [ ".*" ], properties: { context: "default", pull_to_refresh_enabled: true } },
    # Forms: a sheet over what they change, left by Cancel (a sheet's close is Done unless a rule says).
    { patterns: [ "/new$", "/edit$" ], properties: SHEET.merge(close: "cancel") },
    # Settings, from anywhere: a sheet with a stack of its own, as iOS's Settings pushes inside it.
    { patterns: [ "^/settings", "^/agents/\\d+", "^/connectors", "^/subscriptions", "^/helpers$", "^/workspaces" ], properties: SHEET },
    # A waiting card: half the screen, pulled up for the rest.
    { patterns: [ "^/approvals/\\d+$" ], properties: SHEET.merge(modal_style: "medium") },
    # Signing in: a sheet that stays until it is done, or Cancel.
    { patterns: [ "^/sign_in$" ], properties: SHEET.merge(modal_dismiss_gesture_enabled: false, close: "cancel") },
    # The agent's computer screen needs the whole display.
    { patterns: [ "/screen$" ], properties: SHEET.merge(modal_style: "full") },
    # The Settings tab's own list, drawn by the app: never loaded from here.
    { patterns: [ "^/native/settings$" ], properties: { view_controller: "settings" } }
  ].freeze

  # The Settings tab is the web's /settings, with no screen of the app's own:
  # the tab starts there, and each place on it is still a sheet. A build
  # reading ios_v2 has the screen, which only it can draw, so this is new.
  V3 = [
    *V2.reject { it[:properties].key?(:view_controller) },
    { patterns: [ "^/settings$" ], properties: { context: "default", pull_to_refresh_enabled: true } }
  ].freeze

  VERSIONS = { "ios_v1" => V1, "android_v1" => V1, "ios_v2" => V2, "ios_v3" => V3 }.freeze

  # The phone app's tabs, in order: each its own stack, starting at its url, with an SF Symbol (filled when
  # selected). Served, so a tab is renamed or moved without a new build; the app keeps the same list as its
  # fallback (ios/Phone/AppTab.swift). Only a build reading ios_v3 reads them, so they ride there, Settings the
  # web's /settings; a build reading ios_v2 draws its own tabs.
  TABS = [
    { id: "agents", title: "Agents", ios_image: "bubble.left.and.bubble.right", url: "/" },
    # Every card waiting on the person, with their count as its badge (layouts/_badge).
    { id: "needs-you", title: "Needs you", ios_image: "hand.raised", url: "/approvals" },
    { id: "settings", title: "Settings", ios_image: "gearshape", url: "/settings" }
  ].freeze

  SETTINGS = { "ios_v3" => { tabs: TABS } }.freeze

  def self.fetch(version) = { settings: SETTINGS.fetch(version, {}), rules: VERSIONS.fetch(version) }
end
