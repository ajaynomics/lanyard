module Bots
  class SkillsController < ApplicationController
    before_action :set_bot
    before_action :set_skill, only: %i[ edit update destroy ]

    def new
      @skill = @bot.skills.new
    end

    # Typed in the form, or a SKILL.md pasted or uploaded whole.
    def create
      @skill = (text = markdown) ? @bot.skills.from_markdown(text) : @bot.skills.new(skill_params)
      if @skill.save
        redirect_to bot_path(@bot, anchor: "skills"), notice: "Added the #{@skill} skill. #{@bot} can use it from the next message."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @skill.update(skill_params)
        redirect_to bot_path(@bot, anchor: "skills"), notice: "Saved the #{@skill} skill."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @skill.destroy!
      redirect_to bot_path(@bot, anchor: "skills"), notice: "Removed the #{@skill} skill."
    end

    private
      def set_bot
        @bot = Current.user.bots.find(params[:bot_id])
      end

      def set_skill
        @skill = @bot.skills.find(params[:id])
      end

      def skill_params
        params.expect(skill: %i[ name description body ])
      end

      # An upload wins over the pasted box.
      def markdown
        file = params.dig(:skill, :file)
        file.is_a?(ActionDispatch::Http::UploadedFile) ? file.read : params.dig(:skill, :markdown).presence
      end
  end
end
