module Agents
  # The agent's own number for texts, in its Channels (docs/phone.md). Blank
  # takes it away.
  class PhoneNumbersController < ApplicationController
    include AgentSettings

    before_action { head :not_found unless DurableAssistants::Voipms.configured? }

    def update
      if @agent.update(params.expect(agent: %i[ phone_number ]))
        saved agent_channels_path(@agent)
      else
        redirect_to agent_channels_path(@agent), alert: @agent.errors.full_messages.to_sentence
      end
    end
  end
end
