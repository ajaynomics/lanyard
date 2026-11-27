# A workspace's Usage (docs/billing.md): what its own agents' model calls used
# this month and last, or between the dates a member picks, for every member.
# What another workspace used, even one it pays for, is that workspace's own.
class Workspaces::UsagesController < ApplicationController
  layout "settings"

  def show
    @workspace = Current.user.workspaces.find(params[:workspace_id])
    @pilot_budgets = @workspace.pilot_budgets.where(month: Agent::PilotBudget.month_at(Time.current)).includes(:agent, :alerts).order(:agent_id, :kind)
    @from, @to = date(:from), date(:to)
    @periods = if @from || @to
      [ ModelUsage::Period.new(@workspace.model_usages, @from&.beginning_of_day..@to&.end_of_day) ]
    else
      [ Time.current, Time.current.prev_month ].map { ModelUsage::Period.month(@workspace.model_usages, it) }
    end
  end

  private
    # A date field's value, or nil for an empty or unreadable one: the page
    # then shows what it would without it.
    def date(name)
      Date.iso8601(params[name].to_s).in_time_zone if params[name].present?
    rescue Date::Error
      nil
    end
end
