class AgentsController < ApplicationController
  before_action :set_agent, only: %i[ show edit update ]

  def index
    agents = Current.user.agents.order(:created_at)
    redirect_to agent_conversations_path(agents.first) if agents.one?
    @agents = agents
  end

  def show
  end

  def edit
  end

  # `/model` and `/thinking` in a conversation send `command`, and go back to
  # where they were typed; the settings form comes back to the settings.
  def update
    if @agent.update(agent_params)
      notice = "Saved. #{@agent.name} uses this from the next message."
      params[:command] ? redirect_back_or_to(@agent, notice: notice) : redirect_to(@agent, notice: notice)
    elsif params[:command]
      redirect_back_or_to @agent, alert: @agent.errors.full_messages.to_sentence
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_agent
      @agent = Current.user.agents.find(params[:id])
    end

    def agent_params
      params.expect(agent: [ :name, :instructions, :model, :thinking_level, :time_zone, tool_names: [], capabilities: [] ]).tap do |attributes|
        %i[ tool_names capabilities ].each { attributes[it] = Array(attributes[it]).compact_blank if attributes.key?(it) }
      end
    end
end
