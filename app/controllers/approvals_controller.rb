# What needs the person, across all their agents in all their workspaces:
# every card waiting on them, oldest first (User#needs_you), as the badge
# counts. The phone app's Needs you tab starts here and opens each card as a
# sheet to answer; answering one there closes the sheet and refreshes this
# list (Conversations::Invocations::ApprovalsController).
class ApprovalsController < ApplicationController
  def index
    @invocations = Current.user.needs_you
    @several_workspaces = Current.user.workspaces.many?
  end

  # Any of the person's calls: one answered meanwhile shows where it stands.
  def show
    @invocation = find_in_workspace(:invocations, params[:id])
  end
end
