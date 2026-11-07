class AgentsController < ApplicationController
  before_action :set_agent, only: %i[ show edit update ]

  # A name is all a new agent needs: it starts from the install's starter, and
  # its first messages tell it the rest.
  def new
  end

  def create
    attributes = params.expect(agent: %i[ name purpose ])
    agent = Current.user.start_agent(attributes[:name].to_s.squish, purpose: attributes[:purpose])
    redirect_to agent.conversation, status: :see_other
  rescue ActiveRecord::RecordInvalid => invalid
    @agent = invalid.record
    render :new, status: :unprocessable_entity
  end

  def show
  end

  def edit
  end

  # `/model` and `/thinking` in a conversation send `command`, and go back to
  # where they were typed; the settings form comes back to the settings.
  def update
    return choose_model if params[:command] == "model"

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
    # `/model haiku` switches when one model on offer matches, and otherwise
    # says which do, or that none does, in words.
    def choose_model
      words = params.dig(:agent, :model).to_s.strip
      matches = ModelCatalog.matching(words)
      if matches.one? && @agent.update(model: matches.sole.id)
        redirect_back_or_to @agent, notice: "Saved. #{@agent.name} uses #{matches.sole.label} from the next message."
      elsif matches.many?
        redirect_back_or_to @agent, alert: "“#{words}” could be #{matches.map(&:described).to_sentence(two_words_connector: " or ", last_word_connector: ", or ")}. Type more of the one you want."
      else
        offered = ModelCatalog.choices.map(&:described).to_sentence(two_words_connector: " or ", last_word_connector: ", or ")
        redirect_back_or_to @agent, alert: [ (words.empty? ? "Type a model after /model." : "No model matches “#{words}”."), ("You can choose #{offered}." if offered.present?) ].compact.join(" ")
      end
    end

    def set_agent
      @agent = Current.user.agents.find(params[:id])
    end

    def agent_params
      params.expect(agent: [ :name, :email_name, :instructions, :model, :thinking_level, :time_zone, tool_names: [], capabilities: [] ]).tap do |attributes|
        %i[ tool_names capabilities ].each { attributes[it] = Array(attributes[it]).compact_blank if attributes.key?(it) }
      end
    end
end
