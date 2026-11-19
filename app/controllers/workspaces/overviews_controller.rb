# Workspaces › Overview: every workspace the person is in, their own first,
# with what needs them or is broken there. Only links: each thing is dealt
# with on its own page, which checks who may.
class Workspaces::OverviewsController < ApplicationController
  layout "settings"

  def show
    @healths = Workspace::Health.of(Current.user)
  end
end
