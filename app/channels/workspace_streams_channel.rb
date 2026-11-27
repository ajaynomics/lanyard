# The live streams of what is in a workspace: its lists, and each agent's and
# thread's (turbo_stream_from ..., channel: WorkspaceStreamsChannel). Only its
# members hear them, as StreamAudience, in front of Turbo's own channel and so
# of this one, asks at every subscription.
class WorkspaceStreamsChannel < Turbo::StreamsChannel
  def subscribed
    super
    catch_up unless subscription_rejected?
  end

  private
    # A thread's page is drawn from the saved copy; the sidecar is asked only
    # once the page listens, so where the thread stands and what waits for the
    # agent, which move without an entry, reach it by the job's broadcasts
    # (Conversation#sync_quietly). Entries saved before it listened don't: the
    # page names the last entry it drew, and one saved since refreshes it in
    # place. Asked after stream_from, so an entry saved later arrives by its
    # own broadcast, and one saved in between at worst twice, by the same ids.
    # The cursor is only compared: what may be heard is decided above.
    def catch_up
      conversation = GlobalID::Locator.locate(verified_stream_name_from_params, only: Conversation)
      return unless conversation

      conversation.sync_later
      transmit self.class.turbo_stream_refresh_tag if params[:cursor].present? && conversation.last_entry_id.to_i != params[:cursor].to_i
    end
end
