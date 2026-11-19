# Who hears a stream, whichever channel it is asked through. Turbo's own
# channel (Turbo::StreamsChannel) streams any name signed with the app's key,
# and a signed name never expires, so a name kept from a workspace someone has
# left, or copied from another person's page, would be heard there for good.
# What is in a workspace (its lists, an agent, a thread) is heard by its
# members, asked at every subscription; removing someone closes their
# connections (Workspace::Membership), and subscribing again is refused. A
# person's own streams (their badge, their connectors) are theirs alone.
# config/initializers/stream_audience.rb puts it in front of Turbo's channel,
# and so of WorkspaceStreamsChannel.
module StreamAudience
  def subscribed
    audience? ? super : reject
  end

  private
    def audience?
      case record = GlobalID::Locator.locate(verified_stream_name_from_params.to_s.split(":").first)
      when User then record == current_user
      when Workspace then current_user.workspaces.include?(record)
      else (workspace = record.try(:workspace)) && current_user.workspaces.include?(workspace)
      end
    rescue ActiveRecord::RecordNotFound
      false
    end
end
