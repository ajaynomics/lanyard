module Agents
  # The one calendar from another account the agent may reach, in its Channels
  # (docs/calendar.md): the server, the calendar and the vault entry's name,
  # linked together and unlinked together. The password stays in the vault;
  # nothing here takes or shows it.
  class LinkedCalendarsController < ApplicationController
    include AgentSettings

    before_action { head :not_found unless DurableAssistants::Passbolt.configured?(@agent) }

    def update
      if @agent.update(params.expect(agent: %i[ linked_calendar_server linked_calendar linked_calendar_entry ]))
        saved agent_channels_path(@agent)
      else
        render "agents/channels/show", status: :unprocessable_entity
      end
    end

    def destroy
      @agent.update!(linked_calendar_server: nil, linked_calendar: nil, linked_calendar_entry: nil)
      saved agent_channels_path(@agent)
    end
  end
end
