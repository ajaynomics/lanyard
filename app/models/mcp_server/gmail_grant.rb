module McpServer::GmailGrant
  extend ActiveSupport::Concern

  SEARCH = "search_threads"

  included do
    serialize :gmail_grant, coder: JSON
    encrypts :gmail_grant
  end

  def gmail_grant? = gmail_grant.present?

  def gmail_grant_target?(thread)
    thread && thread.id == conversation_id && thread.workspace.id == workspace_id &&
      gmail_grant.values_at("workspace_id", "conversation_id", "agent_id") == [ workspace_id, thread.id, thread.agent_id ]
  end

  def gmail_granted_to?(thread)
    gmail_grant? && enabled? && signed_in? && google == :gmail && gmail_grant["granted_at"].present? &&
      gmail_grant["revoked_at"].nil? && gmail_grant_target?(conversation) && gmail_grant_target?(thread)
  end

  def gmail_grant_owner?(person)
    person && workspace.memberships.owner.exists?(user_id: person.id)
  end

  # A write that started as ordinary OAuth can return after the connector
  # became agent-bound. Check while committing, not only before the request.
  def ordinary_oauth_write(&block)
    if google == :gmail
      with_lock do
        raise McpServer::SignInNeeded, "This connector uses an agent-bound Gmail grant." if gmail_grant?
        block.call
      end
    else
      block.call
    end
  end

  def revoke_gmail_grant!(by:)
    with_lock do
      raise ActiveRecord::RecordNotFound unless gmail_grant? && gmail_grant_owner?(by)
      clear_gmail_grant!(gmail_grant.merge("revoked_at" => Time.current.iso8601))
    end
  end

  def clear_gmail_grant!(receipt)
    google_account_starts.delete_all
    update!(gmail_grant: receipt, enabled: false, oauth_tokens: nil, oauth_pending: nil, oauth_state: nil)
  end
end
