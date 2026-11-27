module DurableAssistants
  module Google
    # Only the Google web-client endpoints. This flow neither discovers a
    # provider from user input nor writes to a connector during code exchange.
    class AccountGrant
      ISSUER = "https://accounts.google.com"
      AUTHORIZE = "#{ISSUER}/o/oauth2/v2/auth"
      PROFILE = URI("#{GMAIL}/profile")
      EMAIL_SCOPE = "https://www.googleapis.com/auth/userinfo.email"
      PROFILE_SCOPES = %w[
        https://www.googleapis.com/auth/gmail.readonly
        https://www.googleapis.com/auth/gmail.compose
        https://www.googleapis.com/auth/gmail.metadata
        https://www.googleapis.com/auth/gmail.modify
        https://mail.google.com/
      ].freeze

      def initialize(client:, scope:, redirect_uri:)
        @client, @scope, @redirect_uri = client, scope, redirect_uri
      end

      def authorization_url(state:, verifier:)
        challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        "#{AUTHORIZE}?#{URI.encode_www_form(client_id: @client.fetch("client_id"), redirect_uri: @redirect_uri,
          response_type: "code", scope: @scope, state: state, code_challenge: challenge, code_challenge_method: "S256",
          access_type: "offline", prompt: "consent select_account")}"
      end

      def exchange(code:, verifier:)
        request = Net::HTTP::Post.new(TOKEN_URL, "Accept" => "application/json")
        form = { grant_type: "authorization_code", code: code, code_verifier: verifier, redirect_uri: @redirect_uri }
        id, secret = @client.values_at("client_id", "client_secret")
        if @client["token_endpoint_auth_method"] == "client_secret_basic"
          request.basic_auth(URI.encode_www_form_component(id), URI.encode_www_form_component(secret))
        else
          form.merge!(client_id: id, client_secret: secret)
        end
        request.set_form_data(form)
        tokens = json(TOKEN_URL, request)
        raise Error, "Google did not return the requested grant" unless valid_grant?(tokens)
        tokens.slice("access_token", "refresh_token", "expires_in", "scope", "token_type").merge("issuer" => ISSUER)
      end

      def address(tokens)
        request = Net::HTTP::Get.new(PROFILE, "Authorization" => "Bearer #{tokens.fetch("access_token")}", "Accept" => "application/json")
        profile = json(PROFILE, request)
        profile["emailAddress"] if profile.is_a?(Hash)
      end

      private
        def json(uri, request)
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { it.request(request) }
          raise Error, "Google declined the request" unless response.is_a?(Net::HTTPSuccess)
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError, *MAY_HAVE_GONE
          raise Error, "Could not read Google’s response"
        end

        def valid_grant?(tokens)
          tokens.is_a?(Hash) && tokens["token_type"].to_s.casecmp?("Bearer") &&
            tokens["expires_in"].is_a?(Integer) && tokens["expires_in"].between?(1, 1.day.to_i) &&
            tokens["scope"].is_a?(String) && scope_names(tokens["scope"]) == scope_names(@scope) &&
            %w[ access_token refresh_token ].all? { |key| tokens[key].is_a?(String) && tokens[key].match?(/\A[!-~]{1,8192}\z/) }
        end

        # Google can return its full email scope URL for the requested OIDC
        # shorthand. Compare the full scope set after normalizing just that alias.
        def scope_names(scope)
          scope.split.map { |name| name == EMAIL_SCOPE ? "email" : name }.uniq.sort
        end
    end
  end
end
