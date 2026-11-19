# What adding a skill ends in, however it came (Agents::SkillsController,
# Agents::GithubSkillsController): the list, or the review when it has
# programs; or the new skill page again, saying what was wrong where the
# person asked.
module SkillAdding
  extend ActiveSupport::Concern

  private
    # from: where the page shows a refusal, :form for the typed form's own
    # fields, or :upload or :github, whose skill the form can't hold.
    def save_added_skill(from: :form)
      if @skill.save
        added_skill
      elsif from == :form
        render "agents/skills/new", status: :unprocessable_entity
      else
        refuse_new_skill(from => refusal)
      end
    end

    def added_skill
      if @skill.needs_review?
        redirect_to agent_skill_path(@agent, @skill), notice: "Added the #{@skill} skill. It has #{@skill.review_reason}, so #{@agent} can't use it until you review it."
      else
        redirect_to agent_skills_path(@agent), notice: "Added the #{@skill} skill. #{@agent} can use it from the next message."
      end
    end

    def refusal
      if @skill.errors.of_kind?(:name, :taken)
        "#{@agent} already has a skill called #{@skill.name}. Remove that one first#{', or check it for an update' if @agent.skills.find_by(name: @skill.name)&.github?}."
      else
        "Its SKILL.md isn't right: #{@skill.errors.full_messages.to_sentence}."
      end
    end

    def refuse_new_skill(upload: nil, github: nil)
      @skill = @agent.skills.new
      @upload_error, @github_error = upload, github
      render "agents/skills/new", status: :unprocessable_entity
    end
end
