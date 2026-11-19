# A workspace's Usage (docs/billing.md): what its own agents' model calls used
# this month and last, for every member. What another workspace used, even one
# it pays for, is that workspace's own.
class Workspaces::UsagesController < ApplicationController
  layout "settings"

  def show
    @workspace = Current.user.workspaces.find(params[:workspace_id])
    @months = [ Time.current, Time.current.prev_month ].map { ModelUsage::Month.new(@workspace.model_usages, starts: it) }
  end
end
