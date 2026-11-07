class ApplicationMailbox < ActionMailbox::Base
  # Every message in the catch-all box; AgentsMailbox finds the agents it names.
  routing all: :agents
end
