# A reply, or its thinking, as it streams, in the blocks Markdown separates
# with a blank line (one before an unindented line, outside a code fence).
# Every block but the last is settled and won't change, so a frame sends each
# block once, as it settles, and the last, still being written, every time
# (Conversation#receive_frame). A list split this way shows as two lists until
# the reply arrives whole.
class LiveText
  FENCE = /\A {0,3}(```|~~~)/

  def initialize(text)
    @text = text.to_s
  end

  def settled = blocks[0...-1]
  def open = blocks.last

  # The settled blocks after those in the text's first `bytes` bytes, the part
  # already sent, with their places.
  def settled_since(bytes)
    before = LiveText.new(@text.byteslice(0, bytes)).settled.size
    settled.drop(before).each.with_index(before)
  end

  private
    def blocks
      @blocks ||= begin
        lines, fenced = @text.lines, false
        lines.each_with_index.with_object([ +"" ]) do |(line, index), blocks|
          fenced = !fenced if line.match?(FENCE)
          if !fenced && line.blank? && blocks.last.present? && lines[index + 1]&.match?(/\A\S/)
            blocks << +""
          else
            blocks.last << line
          end
        end
      end
    end
end
