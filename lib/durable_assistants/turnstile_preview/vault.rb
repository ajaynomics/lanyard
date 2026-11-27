require "fiddle"

module DurableAssistants
  class TurnstilePreview
    class Vault
      LIBRARY = "/usr/local/lib/lanyard-release-vault.so".freeze
      CAPACITY = 257

      def initialize(destination)
        @destination = destination
      end

      def inspect = "#<TurnstilePreview::Vault>"

      def read(record)
        raise_unavailable unless @destination.resource_ids.include?(record)
        return read_native(record) unless Fiber.scheduler

        # Fiddle releases the GVL but holds the request's OS thread.
        Thread.new do
          Thread.current.report_on_exception = false
          read_native(record)
        end.value
      rescue StandardError
        raise_unavailable
      end

      private
        def read_native(record)
          output = "\0".b * CAPACITY
          # The shared library keeps the vault key, passphrase and record value in
          # this process, not in a CLI child's environment or stdout.
          # Load only in the serving worker. Loading before Falcon forks starts
          # Go's runtime threads in the parent; the child inherits runtime state
          # without those threads and cannot safely use it.
          handle = Fiddle.dlopen(LIBRARY)
          type = Fiddle::TYPE_VOIDP
          function = Fiddle::Function.new(handle["ReleaseVaultRead"], [ type ] * 8 + [ Fiddle::TYPE_INT ], Fiddle::TYPE_INT)
          status = function.call(*@destination.vault_parameters(record), output, CAPACITY)
          value = output.split("\0", 2).first
          raise_unavailable unless status.zero? && SECRET.match?(value)
          value
        ensure
          output&.replace("\0".b * CAPACITY)
        end

        def raise_unavailable
          raise Error, "The preview release vault is unavailable.", cause: nil
        end
    end
  end
end
