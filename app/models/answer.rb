class Answer < ApplicationRecord
  belongs_to :invocation
  belongs_to :decided_by, class_name: "User"

  validate :answers_the_question

  private
    def answers_the_question
      options = Array(invocation&.arguments&.dig("options"))
      errors.add(:selections, "must be among the options offered") unless Array(selections).all? { options.include?(it) }
      errors.add(:selections, "allow one choice") if Array(selections).size > 1 && invocation&.arguments&.dig("multiple") != true
      errors.add(:base, "Choose an option or write an answer") if Array(selections).empty? && text.blank?
    end
end
