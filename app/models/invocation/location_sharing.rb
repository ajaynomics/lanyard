module Invocation::LocationSharing
  extend ActiveSupport::Concern

  class InvalidLocation < StandardError; end

  OUTCOMES = {
    "denied" => "The iPhone didn't allow location access.",
    "restricted" => "This iPhone restricts location access.",
    "services_off" => "Location Services is off on this iPhone.",
    "declined" => "The person chose not to share their location.",
    "unavailable" => "The iPhone couldn't get a current location fix.",
    "no_phone" => "No signed-in iPhone was available to share a location."
  }.freeze

  def claim_location!(by:, session_digest:)
    with_lock do
      require_location_request(by)
      raise Invocation::Conflict if location_session_digest.present? || session_digest.blank?
      update!(location_session_digest: session_digest, location_claimed_at: Time.current)
    end
  end

  def share_location!(by:, session_digest:, outcome:, fix:)
    settle_person do
      require_location_request(by)
      raise Invocation::Conflict if session_digest.blank? || location_session_digest != session_digest

      result = if outcome == "shared"
        validated_fix(fix).merge("status" => outcome)
      elsif outcome.in?(%w[ denied restricted services_off unavailable ])
        location_outcome(outcome)
      else
        raise InvalidLocation
      end
      update!(state: :succeeded, result: result, location_session_digest: nil, location_claimed_at: nil)
    end
  end

  def skip_location!(by:, outcome:)
    settle_person do
      require_location_request(by)
      raise Invocation::Conflict if location_session_digest.present?
      raise InvalidLocation unless outcome.in?(%w[ declined no_phone ])
      update!(state: :succeeded, result: location_outcome(outcome))
    end
  end

  private
    # Replacing the tap's card mid-request would disconnect its bridge before it had a chance to ask iOS.
    def location_claim_only? = awaiting_person? && saved_change_to_location_claimed_at? && !saved_change_to_state?

    def require_location_request(by)
      raise Invocation::Conflict unless answerable? && asks == :location && tool_class == Tool::RequestPhoneLocation && by == user
    end

    def location_outcome(outcome) = { "status" => outcome, "message" => OUTCOMES.fetch(outcome) }

    def validated_fix(fix)
      latitude, longitude, accuracy, timestamp = fix.values_at("latitude", "longitude", "accuracy_m", "timestamp")
      raise InvalidLocation unless [ latitude, longitude, accuracy ].all? { it.is_a?(Numeric) && it.finite? }
      raise InvalidLocation unless latitude.between?(-90, 90) && longitude.between?(-180, 180) && accuracy >= 0
      raise InvalidLocation unless timestamp.is_a?(String) && timestamp.bytesize <= 40

      time = Time.iso8601(timestamp)
      raise InvalidLocation unless time.between?(location_claimed_at - 5.seconds, 10.seconds.from_now)
      { "latitude" => latitude, "longitude" => longitude, "accuracy_m" => accuracy, "timestamp" => time.utc.iso8601 }
    rescue ArgumentError
      raise InvalidLocation
    end
end
