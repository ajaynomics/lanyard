# A person's one-time link to their conversation's screen, for someone not
# signed in here (ScreenPass): made on the screen page, its link shown that
# once, and ended there.
class Conversations::ScreenPassesController < ApplicationController
  def create
    @conversation = find_in_workspace(:conversations, params[:conversation_id])
    raise ActiveRecord::RecordNotFound unless @conversation.shareable_screen?
    @pass, token = ScreenPass.issue!(@conversation, by: Current.user)
    @link = screen_pass_url(token)
    render turbo_stream: turbo_stream.replace("screen_share", partial: "conversations/screen_passes/share",
      locals: { conversation: @conversation, passes: @conversation.screen_passes.live.order(:created_at), link: @link })
  end

  def destroy
    conversation = find_in_workspace(:conversations, params[:conversation_id])
    conversation.screen_passes.find(params[:id]).end!
    redirect_to conversation_screen_path(conversation), notice: "The link is ended."
  end
end
