module Agents
  # The agent's Concourse identity, on its settings page: the organization,
  # handle, client id and secret the Concourse operator issued. Saving tests
  # the connection; saving again with the secret left blank keeps it and tests
  # again.
  class ConcourseAgentsController < ApplicationController
    def update
      agent = Current.user.agents.find(params[:agent_id])
      concourse_agent = agent.concourse_agent || agent.build_concourse_agent
      attributes = params.expect(concourse_agent: %i[ organization handle client_id client_secret ])
      attributes.delete(:client_secret) if attributes[:client_secret].blank? && concourse_agent.persisted?
      if concourse_agent.update(attributes)
        if concourse_agent.check
          redirect_to agent, notice: "Connected to Concourse as #{concourse_agent}."
        else
          redirect_to agent, alert: "Saved, but the connection failed: #{concourse_agent.check_error}"
        end
      else
        redirect_to agent, alert: concourse_agent.errors.full_messages.to_sentence
      end
    end

    def destroy
      agent = Current.user.agents.find(params[:agent_id])
      agent.concourse_agent&.tap(&:stop_pushing)&.destroy!
      redirect_to agent, notice: "#{agent} is no longer on Concourse."
    end
  end
end
