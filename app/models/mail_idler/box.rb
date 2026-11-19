# One box an install reads, as the idler watches it: a key saying which box
# it is, how to reach it, and the fetch that reads it when its server says a
# message landed. Both are asked afresh each time, since a box's password is
# read from the vault and its row may have changed since it was listed.
class MailIdler::Box
  # Every box read today (docs/email.md): the install's catch-all, where mail
  # and texts for its agents land; each agent's own inbox; and each
  # workspace's own catch-all.
  def self.watched
    boxes = []
    boxes << install if DurableAssistants::Email.inbox?
    Agent::MailAccount.reading.includes(:agent).find_each do |account| # tenancy-ok: every agent's own inbox, watched as that agent
      boxes << for_account(account.id) if account.reads_inbox?
    end
    Workspace::MailDomain.reading.find_each do |domain| # tenancy-ok: every workspace's own catch-all, watched as that workspace
      boxes << for_domain(domain.id)
    end
    boxes
  end

  def self.install
    new("install", open: -> { DurableAssistants::Email.catch_all }, wake: -> { CatchAllFetchJob.perform_later })
  end

  def self.for_account(id)
    account = -> { Agent::MailAccount.find(id) } # tenancy-ok: this one account, read again for its server and its sign-in
    new("account:#{id}", open: -> { account.call.imap_mailbox }, wake: -> { MailAccountFetchJob.perform_later(account.call) })
  end

  def self.for_domain(id)
    domain = -> { Workspace::MailDomain.find(id) } # tenancy-ok: this one domain, read again for its server and its sign-in
    new("domain:#{id}", open: -> { domain.call.imap_mailbox }, wake: -> { WorkspaceMailFetchJob.perform_later(domain.call) })
  end

  attr_reader :key

  def initialize(key, open:, wake:) = (@key, @open, @wake = key, open, wake)

  def mailbox = @open.call

  def wake = @wake.call
end
