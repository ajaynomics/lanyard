class Tool::Forge::Receipt
  # Stage A never sends a push. A future caller must supply the raw JSON echo,
  # not a reserialization of the parsed operation, before it can settle a hold.
  def self.confirmed(response, challenge:, operation:, sent_operation_json:, echoed_operation_json:, bundle_bytes:, bundle_sha256:)
    return unless operation["verb"] == "push" && Tool::Forge::Wire.success?(operation, response)
    return unless response["challenge"] == challenge && response["operation"] == operation &&
      sent_operation_json.is_a?(String) && sent_operation_json == echoed_operation_json &&
      response.values_at("bundle_bytes", "bundle_sha256") == [ bundle_bytes, bundle_sha256 ]

    response.slice("status", "receipt_id", "bundle_bytes", "bundle_sha256")
  end
end
