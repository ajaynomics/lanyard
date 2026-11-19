require "test_helper"

# One limit for one result, here and in the sidecar (docs/agent.md, "One size
# limit for every result"): an answer Rails fits under it is never one the
# sidecar replaces with a saved file, nor one it lets Durable cut.
class ResultBytesTest < ActiveSupport::TestCase
  test "the limit is the sidecar's RESULT_MAX_BYTES" do
    source = Rails.root.join("agent/whole-results.mjs").read
    kib = source[/^export const RESULT_MAX_BYTES = (\d+) \* 1024;$/, 1]

    assert kib, "agent/whole-results.mjs names RESULT_MAX_BYTES in KiB"
    assert_equal Integer(kib) * 1024, DurableAssistants::ResultBytes::LIMIT
    assert_operator DurableAssistants::ResultBytes::ANSWER, :<, DurableAssistants::ResultBytes::LIMIT
  end

  test "the start of a text fits its bytes as JSON and splits no character" do
    text = "é\"" * 100

    head = DurableAssistants::ResultBytes.head(text, 51)

    assert_operator DurableAssistants::ResultBytes.of(head), :<=, 51
    assert text.start_with?(head)
    assert head.valid_encoding?
  end
end
