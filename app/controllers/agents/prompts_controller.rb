module Agents
  class PromptsController < ApplicationController
    include AgentSettings

    before_action :set_prompt, only: %i[ edit update destroy ]

    def index
    end

    def new
      @prompt = @agent.prompts.new
    end

    def create
      @prompt = @agent.prompts.new(prompt_params)
      if @prompt.save
        redirect_to agent_prompts_path(@agent), notice: "Saved #{@prompt}. Type it in a message to use it."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @prompt.update(prompt_params)
        redirect_to agent_prompts_path(@agent), notice: "Saved #{@prompt}."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @prompt.destroy!
      redirect_to agent_prompts_path(@agent), notice: "Removed #{@prompt}."
    end

    private
      def set_prompt
        @prompt = @agent.prompts.find(params[:id])
      end

      def prompt_params
        params.expect(prompt: %i[ name description body ])
      end
  end
end
