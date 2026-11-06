require "digest"
require "json"

module Agent
  # The sidecar's canonical JSON (agent/state.mjs): object keys sorted at every
  # depth, no spaces. Both sides digest the same bytes, so a digest names one
  # call or one bot definition and nothing else.
  module Canonical
    module_function

    def dump(value)
      case value
      when Hash then "{#{value.map { |key, item| [ key.to_s, item ] }.sort_by(&:first).map { |key, item| "#{JSON.generate(key)}:#{dump(item)}" }.join(',')}}"
      when Array then "[#{value.map { |item| dump(item) }.join(',')}]"
      when Symbol then JSON.generate(value.to_s)
      else JSON.generate(value)
      end
    end

    def digest(value)
      Digest::SHA256.hexdigest(dump(value))
    end
  end
end
