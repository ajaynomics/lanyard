module Agents
  # Where the agent's own calendars live when not on the install's server, in
  # its Channels (docs/calendar.md, "Its own calendar server"): the account's
  # calendar home and the vault entry's name. Only the owner of its workspace
  # sees or changes it, as its mail account; for anyone else it is not there.
  # The password stays in the vault; nothing here takes or shows it.
  class CalendarServersController < ApplicationController
    include AgentSettings

    before_action { head :not_found unless @agent.owned_by?(Current.user) && DurableAssistants::Passbolt.configured?(@agent) }

    def update
      @calendar_server = @agent.calendar_server || @agent.build_calendar_server
      if @calendar_server.update(params.expect(calendar_server: %i[ url vault_entry ]))
        saved agent_channels_path(@agent)
      else
        render "agents/channels/show", status: :unprocessable_entity
      end
    end

    def destroy
      @agent.calendar_server&.destroy!
      saved agent_channels_path(@agent)
    end
  end
end
