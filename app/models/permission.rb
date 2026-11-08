# A person's "Always" for one of an agent's tools that asks first: for every
# call of it, or for calls that reach only recipients they allowed (an email
# address, a Concourse agent, a Campfire room). Made only by the person
# answering a call (Invocation#approve!), and from the call as recorded, so
# nothing the agent reads or writes can widen what it may do unasked. Listed,
# and removable, on the agent's page.
class Permission < ApplicationRecord
  belongs_to :agent
  belongs_to :granted_by, class_name: "User"

  # An empty recipient covers every call of the tool.
  def every_call? = recipient.empty?
end
