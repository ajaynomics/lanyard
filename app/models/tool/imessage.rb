# What the iMessage tools share (docs/imessage.md): they are there only where
# the install names a BlueBubbles server, each picked for an agent on its own,
# and they reach the Mac outside the ledger's lock.
module Tool::Imessage
  extend ActiveSupport::Concern

  GUID = "^(iMessage|SMS|RCS|any);[-+];[^\\s;]+$".freeze

  included do
    effect :external
  end

  class_methods do
    def available? = DurableAssistants::Bluebubbles.configured?
    def label = tool_name.humanize.sub("Imessage", "iMessage")
  end

  def permitted? = self.class.available?

  private
    def bluebubbles = DurableAssistants::Bluebubbles

    def call_bluebubbles
      yield
    rescue DurableAssistants::Bluebubbles::Error => error
      raise Tool::Refusal, error.message
    end
end
