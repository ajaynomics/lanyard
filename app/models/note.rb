class Note < ApplicationRecord
  belongs_to :bot

  validates :key, presence: true, length: { maximum: 64 }, format: { with: /\A[\w.-]+\z/ }
  validates :body, presence: true, length: { maximum: 16_384 }

  scope :matching, ->(query) {
    next all if query.blank?
    pattern = "%#{sanitize_sql_like(query)}%"
    where("key LIKE :pattern OR body LIKE :pattern", pattern: pattern)
  }

  def self.remember(key, body)
    find_or_initialize_by(key: key).tap { it.update!(body: body) }
  end
end
