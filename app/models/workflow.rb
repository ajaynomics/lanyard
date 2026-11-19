# A job of several steps an agent set out as a plain object (Tool::RunWorkflow),
# each step a task for a helper. A fan-out gives every step to its own helper at
# once and gathers what they found; a pipeline runs the steps in order, each
# helper given what the one before found. Each time it runs is a Workflow::Run.
class Workflow < ApplicationRecord
  KINDS = %w[ fan_out pipeline ].freeze
  STEPS = 10
  NAME_LIMIT = 100
  CONTEXT_LIMIT = 20_000

  belongs_to :conversation
  has_many :runs, class_name: "Workflow::Run", dependent: :destroy

  validates :name, presence: true, length: { maximum: NAME_LIMIT }
  validates :kind, inclusion: { in: KINDS }
  validates :context, length: { maximum: CONTEXT_LIMIT }
  validate :steps_are_tasks

  def pipeline? = kind == "pipeline"

  # A run of it, started by the call `call_id`; its steps start in a job.
  def start(call_id:)
    runs.create!(call_id: call_id) do |run|
      steps.each.with_index(1) do |step, position|
        run.steps.build(position: position, task: step["task"], model: step["model"], thinking_level: step["thinking"])
      end
    end
  end

  # How it runs, as a person reads it.
  def shape = pipeline? ? "#{steps.size} #{"step".pluralize(steps.size)} in order" : "#{steps.size} #{"helper".pluralize(steps.size)} at once"

  private
    def steps_are_tasks
      list = Array(steps)
      errors.add(:steps, "must be 1 to #{STEPS}") unless list.size.between?(1, STEPS)
      return if list.all? { it.is_a?(Hash) && it["task"].is_a?(String) && it["task"].strip.present? && it["task"].length <= Helper::TASK_LIMIT &&
        it.values_at("model", "thinking").all? { |chosen| chosen.nil? || chosen.is_a?(String) } }
      errors.add(:steps, "must each have a task of at most #{Helper::TASK_LIMIT} characters")
    end
end
