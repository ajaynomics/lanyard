# What became of turning on the phone app's notifications (docs/native-app.md,
# "Notifications"), so whoever runs the install can see why a phone has no
# Push::Device: registered, or why not. The page says which after a Turn on
# (native/push_device_controller); the app says itself when iOS refused or
# failed, with iOS's error code (PushRegistration). Never the device token,
# which only Push::Device keeps. Only each person's latest few are kept.
class Push::Attempt < ApplicationRecord
  OUTCOMES = %w[ registered no_component refused failed no_answer rejected ].freeze
  KEPT = 20

  belongs_to :user

  # The phone app's Settings tab says Off once iOS refused (SettingsHelper#notifications_status).
  broadcasts_refreshes_to ->(attempt) { [ attempt.user, :settings ] }

  validates :outcome, inclusion: { in: OUTCOMES }

  normalizes :user_agent, with: -> { it.to_s.truncate(500) }, apply_to_nil: true

  after_create :forget_older, :log

  # The app's version, where its user agent says it (AppDelegate: "Lanyard/0.1(12)").
  def app_version = user_agent[%r{\bLanyard/([^\s;]+)}, 1]

  private
    def forget_older
      user.push_attempts.where.not(id: user.push_attempts.order(id: :desc).limit(KEPT).select(:id)).delete_all
    end

    def log
      Rails.logger.info("Push attempt: #{outcome}#{" (#{code})" if code} user=#{user_id} app=#{app_version || "unknown"}")
    end
end
