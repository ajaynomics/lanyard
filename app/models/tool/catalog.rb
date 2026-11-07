# Every tool the model can reach, listed by hand. A name from the wire is only a
# key into this list, never a class name: adding a tool is a line a reviewer
# sees. (Self-registration through `inherited` would depend on what Zeitwerk
# happened to load.)
module Tool::Catalog
  TOOLS = [
    Tool::CurrentTime,
    Tool::RememberNote,
    Tool::ListNotes,
    Tool::ForgetNote,
    Tool::AskPerson
  ].index_by(&:tool_name).freeze

  # Not picked one by one: an agent on Concourse has all four (Agent#tools).
  CONCOURSE = [ Tool::ConcourseFind, Tool::ConcourseGet, Tool::ConcourseSend, Tool::ConcourseReply ].freeze

  def self.names = TOOLS.keys
  def self.find(name) = TOOLS[name]
end
