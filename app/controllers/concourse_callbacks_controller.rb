# Where Concourse sends the person's browser back after they approve or
# cancel a join (the redirect URI, ConcourseAgent::Join.redirect_uri). Only
# the join this browser started, within ten minutes, is finished; anything
# else changes nothing. The agent is found among the person's own.
class ConcourseCallbacksController < ApplicationController
  def show
    join = ConcourseAgent::Join.from(session[:concourse_join])
    agent = Current.user.agents.find_by(id: join&.agent_id)
    unless join&.matches?(params[:state]) && agent
      return redirect_to(agent ? agent_channels_path(agent) : settings_path,
        alert: "That doesn't match a join you started here in the last ten minutes, so nothing changed. Start again.")
    end
    session.delete(:concourse_join)

    if params[:error] == "access_denied"
      redirect_to agent_channels_path(agent), notice: "You cancelled joining Concourse."
    elsif params[:error].present? || !params[:code].is_a?(String)
      redirect_to agent_channels_path(agent), alert: "Concourse did not let #{agent} join, so nothing changed. Start again."
    elsif agent.concourse_agent&.joined?
      redirect_to agent_channels_path(agent), alert: "#{agent} is on Concourse already. Disconnect it before joining again."
    else
      concourse_agent = join.finish(agent, params[:code])
      redirect_to agent_channels_path(agent), notice: concourse_agent.admitted? ? "#{agent} joined Concourse as #{concourse_agent.handle}." :
        "#{agent} asked to join #{concourse_agent.organization} as #{concourse_agent.handle}. An owner there must approve it."
    end
  rescue DurableAssistants::Concourse::Client::Error => problem
    redirect_to agent_channels_path(agent), alert: problem.message
  end
end
