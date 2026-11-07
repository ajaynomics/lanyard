class BotsController < ApplicationController
  before_action :set_bot, only: %i[ show edit update ]

  def index
    bots = Current.user.bots.order(:created_at)
    redirect_to bot_conversations_path(bots.first) if bots.one?
    @bots = bots
  end

  def show
  end

  def edit
  end

  # `/model` and `/thinking` in a conversation send `command`, and go back to
  # where they were typed; the settings form comes back to the settings.
  def update
    if @bot.update(bot_params)
      notice = "Saved. #{@bot.name} uses this from the next message."
      params[:command] ? redirect_back_or_to(@bot, notice: notice) : redirect_to(@bot, notice: notice)
    elsif params[:command]
      redirect_back_or_to @bot, alert: @bot.errors.full_messages.to_sentence
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_bot
      @bot = Current.user.bots.find(params[:id])
    end

    def bot_params
      params.expect(bot: [ :name, :instructions, :model, :thinking_level, :time_zone, tool_names: [], capabilities: [] ]).tap do |attributes|
        %i[ tool_names capabilities ].each { attributes[it] = Array(attributes[it]).compact_blank if attributes.key?(it) }
      end
    end
end
