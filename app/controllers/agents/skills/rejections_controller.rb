module Agents
  module Skills
    # A person refuses a skill's folder: it stays, unused, until they
    # remove it or approve it after all.
    class RejectionsController < ApplicationController
      include AgentSettings
      before_action { @skill = @agent.skills.find(params[:skill_id]) }

      def create
        @skill.reject!
        redirect_to agent_skill_path(@agent, @skill), status: :see_other, notice: "Rejected the #{@skill} skill. #{@agent} won't see it."
      end
    end
  end
end
