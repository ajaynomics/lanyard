module Agents
  module Skills
    # A person approves a skill's folder after reading it (Skill::Review):
    # what they read, named by its digest, and nothing changed since.
    class ApprovalsController < ApplicationController
      include AgentSettings
      before_action { @skill = @agent.skills.find(params[:skill_id]) }

      def create
        @skill.approve!(params[:digest].to_s)
        redirect_to agent_skill_path(@agent, @skill), status: :see_other, notice: "Approved the #{@skill} skill. #{@agent} can use it from the next message."
      rescue Skill::Review::Stale
        redirect_to agent_skill_path(@agent, @skill), status: :see_other, alert: "The #{@skill} skill changed while you were reading it. Read it again, then approve it."
      end
    end
  end
end
