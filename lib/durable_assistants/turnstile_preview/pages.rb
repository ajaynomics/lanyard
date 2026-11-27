module DurableAssistants
  class TurnstilePreview
    class Pages
      BINDING = "TURNSTILE_SECRET".freeze
      REJECTED = [ 400, 401, 403, 404, 422 ].freeze

      def initialize(destination, token, transport)
        @destination, @token, @transport = destination, token, transport
        @path = "/client/v4/accounts/#{destination.account_id}/pages/projects/#{destination.project}"
      end

      def check!
        code, body = @transport.call(Net::HTTP::Get.new(@path), @token)
        preview = checked_preview(code, body)
        unless preview && !preview.fetch("env_vars").key?(BINDING)
          raise Error, "The configured Pages preview is unavailable or already has a Turnstile binding.", cause: nil
        end
        @config_hash = preview["wrangler_config_hash"]
        if @config_hash && !(@config_hash.is_a?(String) && /\A[a-f0-9]{32,128}\z/.match?(@config_hash))
          raise Error, "The Pages preview configuration could not be verified.", cause: nil
        end
      end

      def bind(secret)
        preview = { env_vars: { BINDING => { type: "secret_text", value: secret } } }
        preview[:wrangler_config_hash] = @config_hash if @config_hash
        code, body = @transport.call(Net::HTTP::Patch.new(@path), @token, json: { deployment_configs: { preview: preview } })
        binding = checked_preview(code, body)&.fetch("env_vars")&.fetch(BINDING, nil)
        return :bound if binding.is_a?(Hash) && binding["type"] == "secret_text"
        return :rejected if REJECTED.include?(code) && body.is_a?(Hash) && body["success"] == false
        :unconfirmed
      rescue Error
        :unconfirmed
      end

      private
        def checked_preview(code, body)
          return unless (200..299).cover?(code) && body.is_a?(Hash) && body["success"] == true
          project = body["result"]
          return unless project.is_a?(Hash) && project["id"] == @destination.project_id && project["name"] == @destination.project
          configs = project["deployment_configs"]
          preview = configs["preview"] if configs.is_a?(Hash)
          preview if preview.is_a?(Hash) && preview["env_vars"].is_a?(Hash)
        end
    end
  end
end
