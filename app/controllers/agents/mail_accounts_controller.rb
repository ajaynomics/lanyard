module Agents
  # The agent's own mail account, in its Channels (docs/email.md, "Its own
  # mail account"): the address it sends from, the servers it sends through
  # and reads from, the vault entry's name, the forced Bcc and whether it is
  # the agent's only address. Only the owner of its workspace sees or changes
  # it; for anyone else it is not there. The password stays in the vault;
  # nothing here takes or shows it.
  class MailAccountsController < ApplicationController
    include AgentSettings

    before_action { head :not_found unless @agent.owned_by?(Current.user) && DurableAssistants::Passbolt.configured?(@agent) }

    def update
      @mail_account = @agent.mail_account || @agent.build_mail_account
      if @mail_account.update(params.expect(mail_account: %i[ address display_name smtp_host smtp_port imap_host imap_port vault_entry forced_bcc primary ]))
        saved agent_channels_path(@agent)
      else
        render "agents/channels/show", status: :unprocessable_entity
      end
    end

    def destroy
      @agent.mail_account&.destroy!
      saved agent_channels_path(@agent)
    end
  end
end
