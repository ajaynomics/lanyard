module Agents
  class PromptsController < ApplicationController
    before_action :set_agent
    before_action :set_prompt, only: %i[ edit update destroy ]

    def new
      @prompt = @agent.prompts.new
    end

    def create
      @prompt = @agent.prompts.new(prompt_params)
      if @prompt.save
        redirect_to agent_path(@agent, anchor: "prompts"), notice: "Saved #{@prompt}. Type it in a conversation to use it."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @prompt.update(prompt_params)
        redirect_to agent_path(@agent, anchor: "prompts"), notice: "Saved #{@prompt}."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @prompt.destroy!
      redirect_to agent_path(@agent, anchor: "prompts"), notice: "Removed #{@prompt}."
    end

    private
      def set_agent
        @agent = Current.user.agents.find(params[:agent_id])
      end

      def set_prompt
        @prompt = @agent.prompts.find(params[:id])
      end

      def prompt_params
        params.expect(prompt: %i[ name description body ])
      end
  end
end
