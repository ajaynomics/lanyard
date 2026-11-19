module Agents
  # Mailboxes the agent reads and never sends from, such as a colleague's whose
  # work it took over, in its Channels below its own mail account
  # (docs/email.md, "Read-only mailboxes"). Only the owner of its workspace
  # sees or changes them; for anyone else they are not there. The password
  # stays in the vault; nothing here takes or shows it.
  class MailboxesController < ApplicationController
    include AgentSettings

    before_action { head :not_found unless @agent.owned_by?(Current.user) && DurableAssistants::Passbolt.configured?(@agent) }

    def create
      @mailbox = @agent.mail_accounts.new(params.expect(mailbox: %i[ address imap_host imap_port vault_entry folder_names ]).merge(read_only: true))
      if @mailbox.save
        saved agent_channels_path(@agent)
      else
        render "agents/channels/show", status: :unprocessable_entity
      end
    end

    def destroy
      @agent.mail_accounts.where(read_only: true).find(params[:id]).destroy!
      saved agent_channels_path(@agent)
    end
  end
end
