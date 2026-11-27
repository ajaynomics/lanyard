module Workspaces::AgentSetups
  class RevocationsController < BaseController
    def create
      @setup.revoke!(by: Current.user)
      show_setup("Setup authorization revoked.")
    end
  end
end
