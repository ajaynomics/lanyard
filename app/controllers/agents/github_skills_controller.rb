module Agents
  # A skill installed from a public GitHub repository (Skill::Github), pinned
  # to the commit it was fetched at.
  class GithubSkillsController < ApplicationController
    include AgentSettings, SkillAdding

    def create
      folder, source = Skill::Github.parse(params[:source]).fetch
      @skill = @agent.skills.from_folder(folder, **source)
      save_added_skill(from: :github)
    rescue Skill::Folder::Invalid => error
      refuse_new_skill(github: error.message)
    end
  end
end
