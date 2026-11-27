# Mail to an agent's address in the install's catch-all box goes to its
# thread (ReceivedMail). Mail that names no agent is left alone: the box is
# the whole domain's. Mail to an agent another has replaced goes to that one
# instead (Agent#mail_to_agent). A reply in a thread an agent started from
# an address it has since changed still reaches it (#replied_to). An agent's
# own mailbox elsewhere is read apart and never routed
# (Agent::MailAccount::Inbox).
#
# An agent whose own account is its only address (Agent#mail_primary?) takes
# nothing here: its mail is turned away with one line in the log, naming the
# agent and nothing of the message, and kept like any other. Turned off, the
# next mail reaches it again.
class AgentsMailbox < ApplicationMailbox
  def process
    received = ReceivedMail.new(mail, message_id: inbound_email.message_id)
    agents.each { |agent, addressed| received.deliver_to(agent, addressed) }
  end

  private
    # The envelope recipient of a catch-all box is in Delivered-To or
    # X-Original-To when the message itself names someone else (Bcc). An
    # agent another has replaced passes its mail on, one step, and is not
    # woken (Agent#mail_to_agent). Each agent that takes the mail, with the
    # agents it came through, if any.
    #
    # An address names its agent at its workspace's own domain or at the
    # install's (Workspace::MailDomain): its name is unique across the
    # install, and another workspace's domain names nothing of it.
    def agents
      addresses = (Array(mail.to) + Array(mail.cc) + %w[ Delivered-To X-Original-To ].flat_map { Array(mail.header[it]).map(&:value) })
        .filter_map { it.to_s.downcase.strip[/\A[^@\s<]+@[^@\s>]+\z/]&.split("@", 2) }
      sender = mail.from&.first.to_s.downcase
      replied = replied_to(addresses.map { it.join("@") })
      named = Agent.where(email_name: addresses.map(&:first).uniq).or(Agent.where(id: replied)).includes(:mail_to_agent, :mail_account, workspace: :mail_domain).to_a # tenancy-ok: an address names its agent, whoever owns it
        .select { |agent| agent.id.in?(replied) || addresses.any? { |name, domain| name == agent.email_name && reached_at?(agent, domain) } }
        .reject { turned_away?(it) }
      named.reject { [ it, it.mail_to_agent ].compact.any? { it.email_address == sender } }
        .group_by { it.mail_to_agent || it }.transform_values { |agents| agents.select(&:mail_to_agent) }
    end

    # Agents whose own sent mail this answers (In-Reply-To or References),
    # sent from the very address it now goes to. An address its owner has
    # since changed (Agents::EmailAddressesController) takes no new mail, but
    # a thread the agent started from it still reaches it. Each agent's own
    # sent mail alone: never another's.
    def replied_to(addresses)
      ids = (Array(mail.in_reply_to) + Array(mail.references)).uniq
      return [] if ids.empty?
      Agent.joins(:dispatches).where(dispatches: { provider_id: ids, sender: addresses }).distinct.pluck(:id) # tenancy-ok: its Message-ID names the agent that sent it
    end

    def reached_at?(agent, domain) = domain.in?([ agent.workspace.agents_mail_domain, DurableAssistants::Email.domain ].compact)

    def turned_away?(agent)
      agent.mail_primary?.tap { Rails.logger.info("Email to agent #{agent.id}'s address here not delivered: it uses only its own mail account") if it }
    end
end
