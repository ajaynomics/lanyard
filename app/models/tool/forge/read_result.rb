class Tool::Forge::ReadResult
  # Match the bridge's minimum scan here too, without masking and returning a partial result.
  EXTRA_SHAPES = [ /-----BEGIN [A-Z0-9 ]+-----/, /\b(?:sk-|ghp_|gho_|gta_)[A-Za-z0-9_-]+/,
    /\b(?:proxy-)?authorization[ \t]*:/i, %r{://[^/\s?#]+@},
    /(?:\b(?:token|password|secret)\b[^[:alnum:]\n]{0,12}\b[0-9a-f]{40}\b|\b[0-9a-f]{40}\b[^[:alnum:]\n]{0,12}\b(?:token|password|secret)\b)/i ].freeze

  def self.confirmed(operation, reply, frame)
    return unless Tool::Forge::Wire.success?(operation, reply) && clean?(reply)
    return unless echoed?(operation, reply)

    case operation["verb"]
    when "pr" then reply.except("title") if frame.nil?
    when "ci-runs", "ci-jobs" then reply if frame.nil?
    when "diff"
      patch = Tool::Forge::Patch.excerpt(frame, reply)
      reply.merge(patch) if patch
    end
  end

  def self.clean?(value)
    case value
    when Hash then value.all? { |key, item| clean?(key) && clean?(item) }
    when Array then value.all? { |item| clean?(item) }
    when String
      value.valid_encoding? && EXTRA_SHAPES.none? { |shape| shape.match?(value) } &&
        SecretShapes.mask_piece(value).count.zero?
    else true
    end
  end

  def self.echoed?(operation, reply)
    %w[ number head_sha run_id ].all? { |key| !operation.key?(key) || operation[key] == reply[key] }
  end

  private_class_method :echoed?
end
