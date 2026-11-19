module Agents
  class SkillsController < ApplicationController
    include AgentSettings, SkillAdding

    before_action :set_skill, only: %i[ show edit update destroy ]

    def index
    end

    # Its source, its files and, while it waits, the review.
    def show
    end

    def new
      @skill = @agent.skills.new
    end

    # Typed in the form, a SKILL.md pasted or uploaded whole, or a folder
    # chosen or zipped: every way in goes through the same checks.
    def create
      @skill = if (folder = uploaded_folder) then @agent.skills.from_folder(folder)
      elsif (text = markdown) then @agent.skills.from_markdown(text)
      else @agent.skills.new(skill_params)
      end
      save_added_skill(from: folder ? :upload : :form)
    rescue Skill::Folder::Invalid => error
      refuse_new_skill(upload: error.message)
    end

    def edit
    end

    def update
      if @skill.update(skill_params)
        if @skill.needs_review?
          redirect_to agent_skill_path(@agent, @skill), notice: "Saved the #{@skill} skill. It has #{@skill.review_reason}, so #{@agent} can't use it until you review it again."
        else
          redirect_to agent_skills_path(@agent), notice: "Saved the #{@skill} skill."
        end
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @skill.destroy!
      redirect_to agent_skills_path(@agent), notice: "Removed the #{@skill} skill."
    end

    private
      def set_skill
        @skill = @agent.skills.find(params[:id])
      end

      def skill_params
        params.expect(skill: %i[ name description body ])
      end

      def upload = params.dig(:skill, :file).then { it if it.is_a?(ActionDispatch::Http::UploadedFile) }

      # A chosen folder's files, or one zip.
      def uploaded_folder
        files = Array(params.dig(:skill, :files)).grep(ActionDispatch::Http::UploadedFile)
        files = [ upload ] if files.empty? && upload && Skill::Folder.zip?(upload)
        Skill::Folder.from_uploads(files, Array(params.dig(:skill, :paths)).map(&:to_s)) if files.any?
      end

      # An upload wins over the pasted box.
      def markdown
        upload ? upload.read : params.dig(:skill, :markdown).presence
      end
  end
end
