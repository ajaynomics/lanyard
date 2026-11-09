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
    Tool::AskPerson,
    Tool::MakeAgent,
    Tool::JoinConcourse,
    Tool::CampfireDeleteRoom
  ].index_by(&:tool_name).freeze

  # Not picked one by one: an agent on Concourse has all four (Agent#tools).
  CONCOURSE = [ Tool::ConcourseFind, Tool::ConcourseGet, Tool::ConcourseSend, Tool::ConcourseReply ].freeze

  # Not picked either: every agent with a screen has these where the install
  # has a password manager (Agent#tools, docs/passwords.md).
  SAVED_SIGN_INS = [ Tool::ListSavedSignIns, Tool::SignInWithSavedPassword, Tool::AskForSignIn ].freeze

  # Every agent has these: an agent is changed, and scheduled, by asking it.
  ALWAYS = [ Tool::ChangeYourself, Tool::AddRoutine, Tool::ListRoutines, Tool::RemoveRoutine ].freeze

  # Every agent has a canvas, its documents beside the thread (Document); a
  # person may switch these off for one agent in its Tools (disabled_tools).
  CANVAS = [ Tool::WriteDocument, Tool::EditDocument, Tool::ReadDocument ].freeze

  # An agent that is a Campfire bot has it (docs/campfire.md).
  CAMPFIRE = [ Tool::CampfireSay, Tool::CampfireRooms, Tool::CampfireMakeRoom ].freeze

  # Every agent has it where the install has email (Agent#tools, docs/email.md).
  EMAIL = [ Tool::SendEmail ].freeze

  # An agent with a phone number has it where the install has voip.ms (docs/phone.md).
  PHONE = [ Tool::SendText ].freeze

  # An agent with its own CalDAV account has these where the install names the server (docs/calendar.md).
  CALENDAR = [ Tool::CalendarLists, Tool::CalendarFind, Tool::CalendarSaveEvent, Tool::CalendarSaveTask, Tool::CalendarDelete ].freeze

  def self.names = TOOLS.keys
  def self.find(name) = TOOLS[name]
end
