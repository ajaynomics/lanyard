module Agents
  # Calendar servers whose calendars and task lists the agent reads and never
  # changes, such as a colleague's, in its Channels below its own calendar
  # server (docs/calendar.md, "Read-only calendar servers"). Only the owner of
  # its workspace sees or changes them; for anyone else they are not there.
  class ReadOnlyCalendarsController < ApplicationController
    include AgentSettings

    before_action { head :not_found unless @agent.owned_by?(Current.user) && DurableAssistants::Passbolt.configured?(@agent) }

    def create
      @read_only_calendar = @agent.calendar_servers.new(params.expect(calendar_server: %i[ url vault_entry ]).merge(read_only: true))
      if @read_only_calendar.save
        saved agent_channels_path(@agent)
      else
        render "agents/channels/show", status: :unprocessable_entity
      end
    end

    def destroy
      @agent.calendar_servers.where(read_only: true).find(params[:id]).destroy!
      saved agent_channels_path(@agent)
    end
  end
end
