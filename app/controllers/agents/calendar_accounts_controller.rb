module Agents
  # The agent's own account on the install's CalDAV server, in its Channels
  # (docs/calendar.md). A blank password keeps the one saved; a blank username
  # takes the account away.
  class CalendarAccountsController < ApplicationController
    include AgentSettings

    before_action { head :not_found unless DurableAssistants::Caldav.configured? }

    def update
      account = params.expect(agent: %i[ caldav_username caldav_password ])
      account.delete(:caldav_password) if account[:caldav_password].blank?
      account[:caldav_password] = nil if account[:caldav_username].blank?
      if @agent.update(account)
        saved agent_channels_path(@agent)
      else
        redirect_to agent_channels_path(@agent), alert: @agent.errors.full_messages.to_sentence
      end
    end
  end
end
