module DurableAssistants
  module Google
    class AccountIdentity
      USER_INFO = URI("https://openidconnect.googleapis.com/v1/userinfo").freeze

      # The start compares the address to the one the issuer chose, never to
      # callback parameters. Use only the access token just exchanged for it.
      def self.verify!(access_token:)
        claims = user_info(access_token)
        if claims.is_a?(Hash) && !claims.key?("error") && claims["email_verified"] == true
          email, subject = claims.values_at("email", "sub")
          return true if subject.is_a?(String) && subject.ascii_only? && subject.match?(/\A[!-~]{1,255}\z/) &&
            email.is_a?(String) && yield(email)
        end
        raise Error, "Google did not confirm the expected account"
      end

      def self.user_info(access_token)
        unless access_token.is_a?(String) && access_token.bytesize <= 8192 && access_token.ascii_only? && access_token.match?(%r{\A[A-Za-z0-9._~+/-]+=*\z})
          raise Error, "Google did not return an account identity token"
        end
        request = Net::HTTP::Get.new(USER_INFO, "Authorization" => "Bearer #{access_token}", "Accept" => "application/json")
        response = Net::HTTP.start(USER_INFO.host, USER_INFO.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER,
          open_timeout: TIMEOUT, read_timeout: TIMEOUT) { it.request(request) }
        raise Error, "Google declined the account identity request" unless response.is_a?(Net::HTTPSuccess)
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError, Net::ProtocolError
        raise Error, "Could not read Google's account identity", cause: nil
      end
      private_class_method :user_info
    end
  end
end
