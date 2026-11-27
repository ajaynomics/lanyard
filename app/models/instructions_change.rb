# A change to instructions as the person who allows it reads it: the lines it
# takes out first, since a dropped safeguard is easy to miss in a long new
# text, then the lines it brings in, then the whole of it. An agent's own
# (Tool::ChangeYourself) and a workspace's shared ones (Workspace::Proposal).
class InstructionsChange
  # Past this, after a large cut, the whole new text would bury the removed
  # lines; what it adds is listed line by line above it anyway.
  WHOLE_TEXT_LIMIT = 1_000

  def initialize(from, to)
    @from, @to = lines_of(from), to.to_s
  end

  def removes = @from - lines_of(@to)
  def adds = lines_of(@to) - @from

  # More than half the old text, by characters, so a rewrite that drops the
  # safeguards is named even when the new text is as long as the old.
  def large_cut? = removes.sum(&:length) * 2 > @from.sum(&:length)

  def details
    { "removes" => removes.presence || "Nothing",
      "size" => ("This removes a large part of the instructions." if large_cut?),
      "adds" => adds.presence || "Nothing",
      "instructions" => (@to unless large_cut? && @to.length > WHOLE_TEXT_LIMIT) }.compact
  end

  private
    def lines_of(text) = text.to_s.lines.map(&:rstrip).reject(&:blank?)
end
