module Agents
  # When the agent's mail to people outside the install may go, in its
  # Channels (docs/email.md, "Sending hours"). Only the owner of its
  # workspace sees or changes them; for anyone else they are not there.
  class SendingHoursController < ApplicationController
    include AgentSettings

    before_action { head :not_found unless @agent.owned_by?(Current.user) }

    # Checked on a copy, so the page's other forms of the agent show none of its errors.
    def update
      @sending_hours = @agent.workspace.agents.find(@agent.id)
      if @sending_hours.update(params.expect(agent: %i[ send_from send_until send_time_zone ]))
        saved agent_channels_path(@agent)
      else
        render "agents/channels/show", status: :unprocessable_entity
      end
    end

    def destroy
      @agent.update!(send_from: nil, send_until: nil, send_time_zone: nil)
      saved agent_channels_path(@agent)
    end
  end
end
