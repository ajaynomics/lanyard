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
    Tool::CampfireDeleteRoom,
    # Picked one by one where the install has BlueBubbles (docs/imessage.md):
    # a person's messages are private, so reading them is not every agent's.
    Tool::ImessageChats,
    Tool::ImessageHistory,
    Tool::ImessageAttachment,
    Tool::ImessageSend,
    # Picked one by one where the install has Link (docs/payments.md): an
    # agent pays only once the person switches this on for it.
    Tool::PayByCard,
    # Picked one by one where the install has a password manager
    # (docs/passwords.md): a saved key acts in someone's account.
    Tool::CallApiWithSavedKey,
    # Picked one by one, never a starter's: what the workspace pages do,
    # through an agent (Tool::WorkspaceCalls). Rarely wanted, so no agent
    # carries them unasked; there is no deferring a catalogue tool yet.
    Tool::ListWorkspaces,
    Tool::MakeWorkspace,
    Tool::RenameWorkspace,
    Tool::InviteToWorkspace,
    Tool::ChangeWorkspaceMember,
    Tool::MoveAgent
  ].index_by(&:tool_name).freeze

  # Not picked one by one: an agent on Concourse has all four (Agent#tools).
  CONCOURSE = [ Tool::ConcourseFind, Tool::ConcourseGet, Tool::ConcourseSend, Tool::ConcourseReply ].freeze

  # Not picked either: every agent with a screen has these where the install
  # has a password manager (Agent#tools, docs/passwords.md).
  SAVED_SIGN_INS = [ Tool::ListSavedSignIns, Tool::SignInWithSavedPassword, Tool::AskForSignIn, Tool::AskOutsideForSignIn ].freeze

  # Every agent has these: an agent is changed, and scheduled, by asking it,
  # and reads what waits in its inbox when it chooses (#85).
  ALWAYS = [ Tool::ChangeYourself, Tool::AddRoutine, Tool::ListRoutines, Tool::RemoveRoutine, Tool::WaitingMessages ].freeze

  # Every agent has a canvas, its documents beside the thread (Document); a
  # person may switch these off for one agent in its Tools (disabled_tools).
  # Listing and deleting are not CORE: they are looked up, so they cost no
  # agent a declared tool.
  CANVAS = [ Tool::WriteDocument, Tool::EditDocument, Tool::ReadDocument, Tool::ListDocuments, Tool::DeleteDocument ].freeze

  # An agent that may ask a person (ask_person) has it, looked up: most
  # questions wait for their answer, so few agents ever withdraw one (#84).
  QUESTIONS = [ Tool::WithdrawQuestion ].freeze

  # Every agent has it, looked up: any agent may be asked to allow a call, so
  # any agent may have a card to take back (#251).
  CARDS = [ Tool::WithdrawCard ].freeze

  # An agent that is a Campfire bot has it (docs/campfire.md).
  CAMPFIRE = [ Tool::CampfireSay, Tool::CampfireHistory, Tool::CampfireRooms, Tool::CampfireMakeRoom ].freeze

  # Every agent has it where the install has email (Agent#tools, docs/email.md).
  EMAIL = [ Tool::SendEmail ].freeze

  # An agent with a phone number has it where the install has voip.ms (docs/phone.md).
  PHONE = [ Tool::SendText ].freeze

  # An agent with a Telegram bot has these where it can read the vault
  # (docs/telegram.md). telegram_messages is not in CORE: reading is looked
  # up, so a bot adds no declared tool for catching up on a group or for
  # seeing whether a send of its own arrived (#190, #249).
  TELEGRAM = [ Tool::TelegramSend, Tool::TelegramFile, Tool::TelegramMessages ].freeze

  # An agent with its own CalDAV account has these where the install names the server (docs/calendar.md).
  CALENDAR = [ Tool::CalendarLists, Tool::CalendarFind, Tool::CalendarSaveEvent, Tool::CalendarSaveTask, Tool::CalendarDelete ].freeze

  # The built-ins in every message an agent reads, wherever it has them: what
  # nearly every turn uses (talking to people on its channels, its notes, the
  # time, its canvas, its skills), the sign-in tools beside the screen's
  # desktop and browser, and find_tools and use_tool, which reach the rest.
  # Any other built-in is looked up as a connector's tools are (Agent#toolset),
  # so a rarely used one costs no room and the agent stays under
  # Agent::TOOL_LIMIT (#116). The agent's own calendar and tasks (CalDAV):
  # five small tools that most agents use every day. A Google calendar
  # connector stays looked up, as every connector is. The sidecar adds its own beside these: codemode,
  # and desktop, browser_upload and visit_website where there is a screen.
  CORE = %w[
    ask_person current_time remember_note list_notes forget_note read_skill
    write_document edit_document read_document
    send_email send_text telegram_send telegram_file campfire_say campfire_history campfire_rooms
    concourse_find concourse_get concourse_send concourse_reply
    imessage_chats imessage_history imessage_attachment imessage_send
    list_saved_sign_ins sign_in_with_saved_password ask_for_sign_in
    find_tools use_tool
    calendar_lists calendar_find calendar_save_event calendar_save_task calendar_delete
  ].freeze

  def self.core?(tool) = CORE.include?(tool.tool_name)
  def self.names = TOOLS.keys
  def self.find(name) = TOOLS[name]

  # Any built-in by name, picked or not: what a stored answer (Permission) was for.
  def self.built_in(name) =
    find(name) || [ *QUESTIONS, *CARDS, *CONCOURSE, *SAVED_SIGN_INS, *ALWAYS, *CANVAS, *CAMPFIRE, *EMAIL, *PHONE, *TELEGRAM, *CALENDAR ].find { it.tool_name == name }
end
