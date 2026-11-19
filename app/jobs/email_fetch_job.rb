# Every minute (config/recurring.yml), deliberately global: each box the
# install reads is queued for a read of its own, the install's catch-all
# (CatchAllFetchJob), each agent's own inbox and each mailbox it only reads
# (MailAccountFetchJob), and each workspace's own catch-all
# (WorkspaceMailFetchJob).
#
# The minute is the net under the connections held open on those same boxes
# (MailIdler), which bring a message in seconds: a server that does not offer
# IDLE, a connection dropped without a word, or an idler not running leaves a
# box no more than a minute behind.
class EmailFetchJob < ApplicationJob
  queue_as :mail
  limits_concurrency key: "email_fetch"

  def perform
    CatchAllFetchJob.perform_later if DurableAssistants::Email.inbox?
    Agent::MailAccount.reading.includes(:agent).find_each do |account| # tenancy-ok: every agent's own inbox, each read as that agent
      MailAccountFetchJob.perform_later(account) if account.reads_inbox?
    end
    Workspace::MailDomain.reading.find_each do |domain| # tenancy-ok: every workspace's own catch-all, each read as that workspace
      WorkspaceMailFetchJob.perform_later(domain)
    end
  end
end
