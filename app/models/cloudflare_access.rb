# Who Cloudflare Access says is asking, where Access is the sign-in boundary
# (config/cloudflare_access.yml). Only the signed assertion counts: its RS256
# signature against the team's published keys, the team as issuer, this app's
# audience tag, and time. The plain email header is never read; a Sprite can
# reach kamal-proxy directly and forge it.
class CloudflareAccess
  HEADER = "Cf-Access-Jwt-Assertion"
  Identity = Data.define(:subject, :email)
  NETWORK_ERRORS = [ SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError ].freeze

  class << self
    def configured? = config.team_domain.present? && config.audience.present?

    # The identity in a request's assertion, or nil.
    def identity(request)
      token = request.headers[HEADER].presence
      return unless configured? && token

      jwt = JSON::JWT.decode(token, keys)
      return unless jwt.alg.to_s == "RS256" && trusted?(jwt) && jwt[:email].present?
      Identity.new(subject: jwt[:sub].to_s, email: jwt[:email].to_s.downcase)
    rescue JSON::JWT::Exception, JSON::ParserError, *NETWORK_ERRORS => error
      Rails.logger.warn("[cloudflare_access] assertion refused: #{error.class}")
      nil
    end

    private
      def config = Rails.application.config.x.cloudflare_access

      def trusted?(jwt)
        now = Time.current.to_i
        jwt[:iss] == "https://#{config.team_domain}" && Array(jwt[:aud]).include?(config.audience) &&
          jwt[:exp].to_i > now && jwt[:nbf].to_i <= now + 60
      end

      # The team's public keys rotate rarely; an hour's cache keeps sign-in off the network.
      def keys
        JSON::JWK::Set.new(Rails.cache.fetch("cloudflare_access/certs", expires_in: 1.hour) do
          uri = URI("https://#{config.team_domain}/cdn-cgi/access/certs")
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { it.get(uri.path).body }.then { JSON.parse(it) }
        end)
      end
  end
end
