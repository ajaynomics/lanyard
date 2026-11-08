# One saved state of a document. Never changed: a restore is a new version
# with an old one's words, so the history reads as what happened.
class Document::Version < ApplicationRecord
  AUTHORS = %w[ agent person ].freeze

  belongs_to :document, inverse_of: :versions

  validates :author, inclusion: { in: AUTHORS }
  validates :number, numericality: { only_integer: true, greater_than: 0 }
  validates :body, length: { maximum: Document::BODY_LIMIT }
  validate { errors.add(:body, "can't be nil") if body.nil? }

  after_create_commit :show

  def by_person? = author == "person"

  private
    # Every page showing the document's canvas shows the new version as it
    # lands: its view only, never the box the person may be typing in, whose
    # Save then says the document moved on (Conversations::DocumentsController).
    def show
      html = ApplicationController.render(partial: "conversations/documents/view", locals: { document: document })
      document.agent.conversations.each do |conversation|
        broadcast_replace_to conversation, target: ActionView::RecordIdentifier.dom_id(document, :view), html: html
      end
    end
end
