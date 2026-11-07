# The composer's built-in commands, as its list and the help show them. Each is
# a door to something the app already does (PARITY.md §12): `form` names the
# element that does it, `run` something the browser does on its own.
module CommandsHelper
  Command = Data.define(:name, :hint, :argument, :form, :run, :missing) do
    def label = argument ? "/#{name} #{argument}" : "/#{name}"
  end

  def built_in_commands
    [
      Command.new("new", "Start a new conversation", nil, "command_new", nil, nil),
      Command.new("name", "Rename this conversation", "<name>", "rename_form", nil, "Type a name after /name."),
      Command.new("model", "Choose the model for this bot", "<model>", "command_model", nil, "Choose a model from the list after /model."),
      Command.new("thinking", "Choose how much the bot thinks", "<level>", "command_thinking", nil, "Choose a level from the list after /thinking."),
      Command.new("branch", "Start a new conversation from the last reply", nil, "command_branch", nil, nil),
      Command.new("stop", "Stop the reply in progress", nil, "command_stop", nil, nil),
      Command.new("compact", "Summarise earlier messages to save space", "[what to keep]", "command_compact", nil, nil),
      Command.new("tree", "See this conversation's branches", nil, "command_tree", nil, nil),
      Command.new("export", "Download this conversation as a pi session file", nil, "command_export", nil, nil),
      Command.new("copy", "Copy the last reply", nil, nil, "copy", nil),
      Command.new("help", "Show commands and keyboard shortcuts", nil, nil, "help", nil)
    ]
  end

  # What each key does, for the help.
  def composer_shortcuts
    [
      [ "Enter", "Send what you typed" ],
      [ "Shift + Enter", "New line" ],
      [ "/", "Show commands, saved prompts and skills" ],
      [ "Tab", "Complete the highlighted item (on a phone, tap it)" ],
      [ "↑ ↓", "Move through the list" ],
      [ "Esc", "Close the list" ],
      [ "↑", "In an empty box, bring back your last message" ]
    ]
  end
end
