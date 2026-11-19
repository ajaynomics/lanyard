# A sign-in finished in the phone app's browser sheet and carried back to the
# app, the way OAuth carries a code to a native app (RFC 8252, with PKCE as in
# RFC 7636). Identity providers, Google first, refuse to sign anyone in inside
# an app's own web view, so the app opens the sheet (Safari's own browser) at
# /native_sign_in/new with the challenge of a secret only it knows. Once the
# provider has answered there, Rails sends the sheet to the app's address with
# a code, not a session. The app trades the code and its secret for the
# session cookie in its own web view (ios/TESTFLIGHT.md, "Signing in").
#
# The code is encrypted, so it says nothing to whoever sees the address, and
# lasts two minutes. It is good once: its id is written to the cache on first
# use, and a second write of the same id fails. Without the secret it is worth
# nothing, so a code another app catches on the way back signs nobody in.
class NativeSignIn
  EXPIRES_IN = 2.minutes
  # Base64url of a SHA-256 digest, which is all S256 can be.
  CHALLENGE = /\A[A-Za-z0-9_-]{43}\z/
  # RFC 7636's verifier: 43 to 128 unreserved characters.
  VERIFIER = /\A[A-Za-z0-9._~-]{43,128}\z/
  SCHEME = /\A[a-z][a-z0-9+.-]*\z/
  # What a browser-based address is, never an app's.
  WEB_SCHEMES = %w[ http https javascript data file about blob ].freeze

  attr_reader :user, :email

  class << self
    def challenge?(challenge) = challenge.is_a?(String) && challenge.match?(CHALLENGE)

    # Where the sheet goes once the provider has said who this is: the app's
    # own address (APP__NATIVE_SIGN_IN_SCHEME), with the code.
    def return_url(user, email:, challenge:)
      code = encryptor.encrypt_and_sign({ "id" => SecureRandom.uuid, "user_id" => user.id, "email" => email, "challenge" => challenge },
        expires_in: EXPIRES_IN, purpose: :native_sign_in)
      "#{scheme}://signed-in?#{{ code: code }.to_query}"
    end

    # The sign-in a code and its verifier stand for, or nil: forged, expired,
    # used before, or the wrong verifier. A code is spent by its first try,
    # right or wrong.
    def redeem(code, verifier:)
      payload = encryptor.decrypt_and_verify(code, purpose: :native_sign_in) if code.is_a?(String)
      return unless payload && spend(payload["id"])
      return unless verifier.is_a?(String) && verifier.match?(VERIFIER)
      return unless ActiveSupport::SecurityUtils.secure_compare(challenge_of(verifier), payload["challenge"].to_s)

      user = User.find_by(id: payload["user_id"]) # tenancy-ok: the code names the person who signed in
      new(user, payload["email"]) if user
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      nil
    end

    def challenge_of(verifier) = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

    # The app's own URL scheme, from settings. Asked at boot
    # (config/initializers/native_sign_in.rb), so a typo fails there.
    def scheme
      value = DurableAssistants.config(:app, :native_sign_in_scheme, default: "org.durableassistants.companion").to_s
      return value if value.match?(SCHEME) && !value.in?(WEB_SCHEMES)
      raise ArgumentError, "APP__NATIVE_SIGN_IN_SCHEME must be an app's own URL scheme in lower case (letters, digits, + . -), not #{value.inspect}"
    end

    private
      def encryptor
        ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key("native sign-in", 32), url_safe: true)
      end

      def spend(id) = id.present? && Rails.cache.write("native-sign-in/#{id}", true, unless_exist: true, expires_in: EXPIRES_IN + 1.minute)
  end

  def initialize(user, email)
    @user, @email = user, email
  end
end
