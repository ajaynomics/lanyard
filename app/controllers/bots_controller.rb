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

  def update
    if @bot.update(bot_params)
      redirect_to @bot, notice: "Saved. #{@bot.name} uses this from the next message."
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
