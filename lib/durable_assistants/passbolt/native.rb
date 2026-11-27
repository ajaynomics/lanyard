require "fiddle"
require "json"

module DurableAssistants
  module Passbolt
    class Native
      CAPACITY = 8 * 1024 * 1024
      LIBRARY = "/usr/local/lib/lanyard-release-vault.so".freeze

      def self.call(origin:, key:, passphrase:, operation:, id: nil, internal_hosts: "")
        input = JSON.generate(origin:, key:, passphrase:, operation:, id:, internal_hosts:)
        return exchange(input) unless Fiber.scheduler

        Thread.new do
          Thread.current.report_on_exception = false
          exchange(input)
        end.value
      rescue StandardError
        raise Error, "The password manager could not be reached.", cause: nil
      end

      def self.exchange(input)
        output = "\0".b * CAPACITY
        # Load in the serving worker, never before Falcon forks. The process
        # holds the keys and result; no helper, command line or temp key file.
        handle = Fiddle.dlopen(LIBRARY)
        pointer, integer = Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT
        function = Fiddle::Function.new(handle["ProductVaultRead"], [ pointer, integer, pointer, integer ], integer)
        length = function.call(input, input.bytesize, output, CAPACITY)
        raise Error unless length.positive? && length <= CAPACITY
        JSON.parse(output.byteslice(0, length))
      ensure
        output&.replace("\0".b * CAPACITY)
        input.replace("\0" * input.bytesize)
      end
      private_class_method :exchange
    end
  end
end
