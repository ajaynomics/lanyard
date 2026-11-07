module Bots
  class PromptsController < ApplicationController
    before_action :set_bot
    before_action :set_prompt, only: %i[ edit update destroy ]

    def new
      @prompt = @bot.prompts.new
    end

    def create
      @prompt = @bot.prompts.new(prompt_params)
      if @prompt.save
        redirect_to bot_path(@bot, anchor: "prompts"), notice: "Saved #{@prompt}. Type it in a conversation to use it."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @prompt.update(prompt_params)
        redirect_to bot_path(@bot, anchor: "prompts"), notice: "Saved #{@prompt}."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @prompt.destroy!
      redirect_to bot_path(@bot, anchor: "prompts"), notice: "Removed #{@prompt}."
    end

    private
      def set_bot
        @bot = Current.user.bots.find(params[:bot_id])
      end

      def set_prompt
        @prompt = @bot.prompts.find(params[:id])
      end

      def prompt_params
        params.expect(prompt: %i[ name description body ])
      end
  end
end
