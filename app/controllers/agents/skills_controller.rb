module Agents
  class SkillsController < ApplicationController
    before_action :set_agent
    before_action :set_skill, only: %i[ edit update destroy ]

    def new
      @skill = @agent.skills.new
    end

    # Typed in the form, or a SKILL.md pasted or uploaded whole.
    def create
      @skill = (text = markdown) ? @agent.skills.from_markdown(text) : @agent.skills.new(skill_params)
      if @skill.save
        redirect_to agent_path(@agent, anchor: "skills"), notice: "Added the #{@skill} skill. #{@agent} can use it from the next message."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @skill.update(skill_params)
        redirect_to agent_path(@agent, anchor: "skills"), notice: "Saved the #{@skill} skill."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @skill.destroy!
      redirect_to agent_path(@agent, anchor: "skills"), notice: "Removed the #{@skill} skill."
    end

    private
      def set_agent
        @agent = Current.user.agents.find(params[:agent_id])
      end

      def set_skill
        @skill = @agent.skills.find(params[:id])
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
