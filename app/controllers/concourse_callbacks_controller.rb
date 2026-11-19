# Where Concourse sends the person's browser back after they approve or
# cancel a join (the redirect URI, ConcourseAgent::Join.redirect_uri). Only
# the join this browser started, within ten minutes, is finished; anything
# else changes nothing. The agent is found among the person's own. A join
# outside the workspace's home network is a bridge (ConcourseAgent::Bridge).
class ConcourseCallbacksController < ApplicationController
  def show
    join = ConcourseAgent::Join.from(session[:concourse_join])
    agent = Current.workspace.agents.find_by(id: join&.agent_id)
    unless join&.matches?(params[:state]) && agent
      return redirect_to(agent ? agent_channels_path(agent) : settings_path,
        alert: "That doesn't match a join you started here in the last ten minutes, so nothing changed. Start again, under a new handle: " \
          "Concourse retires an agent this app doesn't collect within ten minutes.")
    end
    session.delete(:concourse_join)

    if params[:error] == "access_denied"
      redirect_to agent_channels_path(agent), notice: "You cancelled joining Concourse."
    elsif params[:error].present? || !params[:code].is_a?(String)
      redirect_to agent_channels_path(agent), alert: "Concourse did not let #{agent} join, so nothing changed. Start again."
    else
      concourse_agent = join.finish(agent, params[:code], joiner: Current.user)
      redirect_to agent_channels_path(agent), notice: joined(agent, concourse_agent)
    end
  rescue DurableAssistants::Concourse::Client::Error => problem
    redirect_to agent_channels_path(agent), alert: problem.message
  end

  private
    def joined(agent, concourse_agent)
      network, workspace = concourse_agent.organization, agent.workspace
      said = concourse_agent.admitted? ? "#{agent} joined #{network} as #{concourse_agent.handle}" :
        "#{agent} asked to join #{network} as #{concourse_agent.handle}. An owner there must approve it"
      if concourse_agent.waiting_for_owner?
        "#{said}. #{network} is outside #{workspace}'s home network, #{workspace.concourse_home}, so it waits for #{workspace.owner} to approve it."
      elsif concourse_agent.bridge?
        "#{said}, a bridge outside #{workspace}'s home network, which you approved."
      else
        "#{said}."
      end
    end
end
