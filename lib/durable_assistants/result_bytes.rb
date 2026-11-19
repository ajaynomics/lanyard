module DurableAssistants
  # The most one tool result may take, the sidecar's RESULT_MAX_BYTES
  # (agent/whole-results.mjs; docs/agent.md, "One size limit for every
  # result"), counted as the sidecar sends it on: JSON, in UTF-8. Past it the
  # sidecar saves the whole result and passes on only where, its size and its
  # start. So a reader here decides "too long" by those bytes, never by
  # characters, which a non-ASCII text passes at up to three bytes each; what
  # is too long is saved whole, never cut.
  module ResultBytes
    LIMIT = 49_152
    # What one answer may take, leaving room for what the sidecar adds to it
    # (saved paths, a note).
    ANSWER = LIMIT - 3_200

    def self.of(value) = JSON.generate(value).bytesize

    # The longest start of text whose JSON takes at most bytes: escapes
    # (a quote, a newline) count, and no character is split.
    def self.head(text, bytes)
      head = text.to_s.byteslice(0, bytes).scrub("")
      while (over = of(head) - bytes).positive?
        head = head.byteslice(0, head.bytesize - over).scrub("")
      end
      head
    end
  end
end
