module Agents
  module Skills
    # A skill from GitHub never updates itself. Checking shows what changed
    # since its pinned commit; applying fetches that commit and, when either
    # version has files, the skill waits for review again (Skill::Review).
    class UpdatesController < ApplicationController
      include AgentSettings
      before_action { @skill = @agent.skills.find(params[:skill_id]) }
      before_action { head :not_found unless @skill.github? }

      def show
        source = Skill::Github.for(@skill)
        @sha = source.latest_sha
        return if @sha == @skill.github_sha
        folder, = source.fetch(sha: @sha, known: @skill.files)
        @diff = Skill::Diff.between(@skill, folder)
      rescue Skill::Folder::Invalid => error
        @error = error.message
      end

      def create
        sha = params[:sha].to_s
        return redirect_to agent_skill_update_path(@agent, @skill), status: :see_other, alert: "That isn't a commit." unless sha.match?(/\A\h{40}\z/)
        folder, source = Skill::Github.for(@skill).fetch(sha: sha, known: @skill.files)
        @skill.replace_with(folder, github_sha: source[:github_sha])
        redirect_to agent_skill_path(@agent, @skill), status: :see_other, notice: @skill.needs_review? ?
          "Updated the #{@skill} skill to #{sha.first(7)}. #{@agent} can't use it until you review it again." :
          "Updated the #{@skill} skill to #{sha.first(7)}."
      rescue Skill::Folder::Invalid, ActiveRecord::RecordInvalid => error
        redirect_to agent_skill_update_path(@agent, @skill), status: :see_other, alert: "Nothing was changed: #{error.message}"
      end
    end
  end
end
