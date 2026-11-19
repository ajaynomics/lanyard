# Masks what looks like a secret in a report Rails sends the agent as a
# message: a handed-back card's result, a helper's or a workflow's answer.
# The sidecar masks every tool result the same way (agent/secret-mask.mjs),
# from the same shapes, config/secret_shapes.json; test/fixtures/secret_shapes.json
# holds both to the same answers.
#
# Masking is a backstop, not a permission: agents still never print secrets.
module SecretShapes
  MASKED = "[masked]".freeze

  SHAPES = JSON.parse(Rails.root.join("config/secret_shapes.json").read).map { |shape|
    shape.merge("regexp" => Regexp.new(shape.fetch("pattern")))
  }.freeze

  # A long run is a secret only when it mixes cases and digits like one: an id
  # of words, a timestamp or a hash does not. Base64 over 1 KB is a picture or
  # a file, never a key, and a run after `base64,` is a data: URI.
  LONGEST_KEY = 1024
  MIXED = 3
  URL_TEXT = %r{https?://[^\s"'<>`]+}
  ORIGIN = %r{\A(https?)://([^/?#\s:@]+)(?::(\d+))?(?=[/?#]|\z)}

  Masked = Data.define(:text, :count) do
    def note = "[masked #{count} secret-shaped #{count == 1 ? "value" : "values"}]"
  end

  module_function

  # A link on exactly this install's origin (APP__URL) is the app's own, such
  # as a sign-in link the agent must send on; a host that only looks like it
  # is masked as any other.
  def mask(text, app_url: DurableAssistants.config(:app, :url))
    return Masked.new(text, 0) unless text.is_a?(String) && text.present?
    own = origin(app_url.to_s)
    count, out, at = 0, +"", 0
    masked = ->(piece) { mask_piece(piece).tap { count += it.count }.text }
    if own
      text.to_enum(:scan, URL_TEXT).each do
        found = Regexp.last_match
        next unless origin(found[0]) == own
        out << masked.(text[at...found.begin(0)]) << found[0]
        at = found.end(0)
      end
    end
    out << masked.(text[at..])
    Masked.new(out, count)
  end

  def mask_piece(text)
    count = 0
    SHAPES.each do |shape|
      text = text.gsub(shape["regexp"]) do
        found = Regexp.last_match
        if shape["entropy"]
          entropy_mask(found[0], found.pre_match, shape["entropy"]) { count += 1 }
        else
          count += 1
          "#{found[1] if shape["keep"]}#{MASKED}"
        end
      end
    end
    Masked.new(text, count)
  end

  def entropy_mask(run, before, threshold)
    return run if run.length > LONGEST_KEY || before.end_with?("base64,")
    run.split("/", -1).map { |part| secret_shaped?(part, threshold) ? (yield; MASKED) : part }.join("/")
  end

  def secret_shaped?(part, threshold)
    return false if part.length < 32 || part.match?(/\A[0-9A-Fa-f-]+\z/)
    part.count("A-Z") >= MIXED && part.count("a-z") >= MIXED && part.match?(/[0-9]/) && entropy(part) >= threshold
  end

  def entropy(text)
    text.each_char.tally.values.sum { |seen| share = seen.fdiv(text.length); -share * Math.log2(share) }
  end

  def origin(url)
    found = url.match(ORIGIN) or return
    scheme = found[1].downcase
    [ scheme, found[2].downcase, found[3] || (scheme == "https" ? "443" : "80") ]
  end
end
