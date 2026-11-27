module DurableAssistants
  class TurnstilePreview
    class Destination
      HOSTNAME = /\A(?=.{1,150}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]\z/
      UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/
      PROJECT = /\A[a-z0-9](?:[a-z0-9-]{0,56}[a-z0-9])?\z/
      ENVIRONMENT = "preview".freeze
      SETTINGS = %i[ account_id hostname project project_id token_resource_id pages_token_resource_id vault_url vault_ca
        vault_user_id vault_resource_type_id vault_private_key vault_passphrase ].freeze

      def self.for(agent)
        return unless DurableAssistants.config(:turnstile_preview, :enabled) == true
        return unless DurableAssistants.config(:turnstile_preview, :workspace_id).to_s == agent.workspace_id.to_s
        owner = agent.workspace.owner
        return unless owner && DurableAssistants.config(:turnstile_preview, :owner_email) == owner.email && Admission.admits?(owner.email)

        settings = SETTINGS.index_with { |key| DurableAssistants.config(:turnstile_preview, key).to_s }
        new(settings, owner.id).then { |destination| destination if destination.valid_for?(agent) }
      end

      def initialize(settings, owner_id)
        @settings, @owner_id = settings, owner_id
      end

      def account_id = @settings.fetch(:account_id)
      def hostname = @settings.fetch(:hostname)
      def project = @settings.fetch(:project)
      def project_id = @settings.fetch(:project_id)
      def resource_ids = @settings.values_at(:token_resource_id, :pages_token_resource_id)
      def inspect = "#<TurnstilePreview::Destination>"

      def vault_parameters(record)
        @settings.values_at(:vault_url, :vault_ca, :vault_user_id) + [ record ] +
          @settings.values_at(:vault_resource_type_id, :vault_private_key, :vault_passphrase)
      end

      def digest
        Digest::SHA256.hexdigest([ @owner_id, ENVIRONMENT, account_id, hostname, project, project_id, resource_ids,
          @settings.values_at(:vault_url, :vault_user_id, :vault_resource_type_id), Digest::SHA256.hexdigest(@settings.fetch(:vault_ca)) ].to_json)
      end

      def valid_for?(agent)
        return false unless /\A[0-9a-f]{32}\z/.match?(account_id) && HOSTNAME.match?(hostname) && PROJECT.match?(project)
        return false unless [ project_id, *resource_ids, *@settings.values_at(:vault_user_id, :vault_resource_type_id) ].all? { UUID.match?(it) }
        return false if resource_ids.uniq.size != 2 || @settings.values.any? { |value| value.blank? || value.include?("\0") }
        key = @settings.fetch(:vault_private_key)
        ordinary_keys = [ DurableAssistants.config(:passbolt, :private_key), agent.passbolt_private_key, agent.workspace.passbolt_private_key ].compact
        ordinary_keys.none? { |ordinary| normalize_key(ordinary) == normalize_key(key) }
      end

      private
        def normalize_key(key) = key.gsub("\\n", "\n").strip
    end
  end
end
