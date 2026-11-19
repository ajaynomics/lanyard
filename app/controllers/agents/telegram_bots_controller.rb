module Agents
  # The agent's Telegram bot, in its Channels (docs/telegram.md): the name of
  # the vault entry holding the bot's token. Only the owner of its workspace
  # sees or changes it; for anyone else it is not there. Saving reads the
  # token from the vault to tell Telegram where to post; nothing here takes
  # or shows it.
  class TelegramBotsController < ApplicationController
    include AgentSettings

    before_action { head :not_found unless @agent.owned_by?(Current.user) && DurableAssistants::Passbolt.configured?(@agent) }

    def update
      @telegram_bot = @agent.telegram_bot || @agent.build_telegram_bot
      @telegram_bot.vault_entry = params.expect(telegram_bot: [ :vault_entry ])[:vault_entry]
      if @telegram_bot.connect
        saved agent_channels_path(@agent)
      else
        render "agents/channels/show", status: :unprocessable_entity
      end
    end

    def destroy
      if (bot = @agent.telegram_bot)
        bot.disconnect
        bot.destroy!
      end
      saved agent_channels_path(@agent)
    end
  end
end
