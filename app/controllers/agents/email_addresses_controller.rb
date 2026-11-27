module Agents
  # The agent's address, on its General page. Only the owner of its workspace
  # changes it: the old address stops taking new mail, for everyone who knew
  # it. Replies in threads the agent started from it still reach it
  # (AgentsMailbox).
  class EmailAddressesController < ApplicationController
    include AgentSettings

    before_action { head :not_found unless @agent.owned_by?(Current.user) }

    def update
      if @agent.update(params.expect(agent: %i[ email_name ]))
        saved @agent
      else
        # The error sits at the field, which keeps what was typed; the rest of
        # the page shows the address it keeps.
        @agent.restore_attributes
        render "agents/show", status: :unprocessable_entity
      end
    end
  end
end
