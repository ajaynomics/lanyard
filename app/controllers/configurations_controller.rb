# The path configuration a Hotwire Native app reads at launch, before anyone
# signs in: which screens open as a modal and where pull-to-refresh is off.
# Rules, nothing about anyone. Issue #7 builds the apps; this is their seam.
class ConfigurationsController < ApplicationController
  allow_unauthenticated_access

  def show
    expires_in 1.hour, public: true
    render json: { settings: {}, rules: RULES }
  end

  RULES = [
    { patterns: [ ".*" ], properties: { context: "default", pull_to_refresh_enabled: true } },
    # Forms and the screen: a modal, closed by Done, not a page in the stack.
    { patterns: [ "/new$", "/edit$", "/screen$" ], properties: { context: "modal", pull_to_refresh_enabled: false } },
    # A thread scrolls to its end and loads earlier messages as it is pulled down.
    { patterns: [ "/conversations/\\d+$" ], properties: { pull_to_refresh_enabled: false } }
  ].freeze
end
