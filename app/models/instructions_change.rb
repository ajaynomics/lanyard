# A change to instructions as the person who allows it reads it: the lines it
# takes out first, since a dropped safeguard is easy to miss in a long new
# text, then the lines it brings in, then the whole of it. An agent's own
# (Tool::ChangeYourself) and a workspace's shared ones (Workspace::Proposal).
class InstructionsChange
  def initialize(from, to)
    @from, @to = lines_of(from), to.to_s
  end

  def removes = @from - lines_of(@to)
  def adds = lines_of(@to) - @from

  def details
    { "removes" => removes, "adds" => adds }.transform_values { it.presence || "Nothing" }.merge("instructions" => @to)
  end

  private
    def lines_of(text) = text.to_s.lines.map(&:rstrip).reject(&:blank?)
end
