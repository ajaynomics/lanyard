# A person's own Link wallet (docs/payments.md), connected by Link's device
# sign-in: this install shows a phrase, the person enters it at Link, then
# says they have. The session holds either that sign-in, waiting, or Link's
# tokens, encrypted; never a card.
module User::Wallet
  extend ActiveSupport::Concern

  RENEW_BEFORE = 1.minute

  included do
    serialize :link_session, coder: JSON
    encrypts :link_session
  end

  def wallet_connected? = link_session&.key?("refresh_token") == true

  # The phrase and address while a sign-in waits for the person, until it expires.
  def wallet_sign_in = (link_session if link_session&.key?("phrase") && Time.zone.at(link_session["expires_at"].to_i).future?)

  # Every sign-in Link finishes is one more connection in the person's Link
  # app, and only the one kept here can be revoked from here. So a wallet
  # already connected is never signed in again, and a sign-in waiting here
  # that Link has already had the phrase for is finished rather than
  # dropped. True when that leaves the wallet connected, so the person is
  # told it is; false when a new phrase waits. Link is asked outside the
  # lock: on SQLite a lock held through a slow call would stop every write.
  def start_wallet_sign_in!
    reload
    return true if wallet_connected?
    return true if wallet_sign_in && finished_before_starting_again?

    sign_in = DurableAssistants::Link.start_sign_in
    with_lock do
      next true if wallet_connected?
      update!(link_session: sign_in)
      false
    end
  end

  # True once Link has the person's yes, or already had it; false while it waits for it.
  def finish_wallet_sign_in!
    reload
    return true if wallet_connected?
    raise DurableAssistants::Link::Error, "The sign-in expired. Connect again." unless wallet_sign_in
    finish_pending_sign_in
  end

  # Link is told too, so the install's access ends there, not only here. Any
  # payment still open is cancelled first, its card closed while this
  # install can still ask Link to.
  def disconnect_wallet!
    if wallet_connected?
      payment_requests.where(state: PaymentRequest::OPEN).each { it.cancel!(by: self) }
      begin
        DurableAssistants::Link.revoke(link_session["refresh_token"])
      rescue DurableAssistants::Link::Error => error
        Rails.logger.warn("Link didn't revoke a wallet's sign-in: #{error.message}")
      end
    end
    update!(link_session: nil)
  end

  # A current access token, renewed first when it is about to run out. Read
  # under the lock, which reloads, so a wallet disconnected since this copy
  # was loaded has none.
  def wallet_token
    with_lock do
      raise DurableAssistants::Link::Error, "No Link wallet is connected." unless wallet_connected?
      if Time.zone.at(link_session["expires_at"].to_i) < RENEW_BEFORE.from_now
        update!(link_session: link_session.merge(DurableAssistants::Link.refresh(link_session["refresh_token"])))
      end
    end
    link_session["access_token"]
  end

  private
    # Link refusing the waiting one, expired or declined there, still lets the
    # person start again; Link out of reach stops it, so nothing is dropped.
    def finished_before_starting_again?
      finish_pending_sign_in
    rescue DurableAssistants::Link::Error => error
      raise unless error.code
      false
    end

    # Kept only if no other tab or press connected the wallet meanwhile;
    # otherwise this second connection is revoked at Link at once.
    def finish_pending_sign_in
      tokens = DurableAssistants::Link.finish_sign_in(link_session["device_code"]) or return false
      kept = with_lock do
        next false if wallet_connected?
        update!(link_session: tokens.merge("connected_at" => Time.current.to_i))
      end
      revoke_surplus(tokens["refresh_token"]) unless kept
      true
    end

    def revoke_surplus(refresh_token)
      DurableAssistants::Link.revoke(refresh_token)
    rescue DurableAssistants::Link::Error => error
      Rails.logger.warn("Link didn't revoke a second wallet sign-in: #{error.message}")
    end
end
