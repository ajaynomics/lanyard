# The phone's Share sheet, once the app is installed (the manifest's
# share_target): words, a link and pictures arrive here as a form post. It
# sends nothing: it keeps them (Share) and asks which agent they are for,
# or, with only one agent, goes straight to its composer, filled in, where
# the person presses Send.
class SharesController < ApplicationController
  # Signed out, the share cannot wait for sign-in: its pictures came with
  # this one request, so the person is asked to share again.
  prepend_before_action :ask_to_share_again, only: :create

  def create
    share = Current.user.shares.new(text: Share.text_from(title: params[:title], text: params[:text], url: params[:url]))
    refusals = share.stage(Array(params[:files]).grep(ActionDispatch::Http::UploadedFile))
    flash[:alert] = refusals.join(" ") if refusals.any?
    return redirect_to(root_path, alert: flash[:alert] || "Nothing came with that share.", status: :see_other) if share.empty?

    share.save!
    threads = Current.user.conversations.threads.active.limit(2).to_a
    redirect_to threads.one? ? conversation_path(threads.first, share: share) : share_path(share), status: :see_other
  end

  # "Share with…": the person's agents, each opening its composer with the share in it.
  def show
    @share = Current.user.shares.find(params[:id])
    @conversations = Current.user.conversations.threads.active.includes(:agent).sorted_by("recent").strict_loading
  end

  private
    # The Share sheet posts as a navigation the person started outside any
    # page, so it has no CSRF token to send. Browsers mark exactly that with
    # Sec-Fetch-Site: none, a header no page can set or forge; another
    # site's form says cross-site. So "none" is let through here, for this
    # action alone, and everything else is checked as every other form is.
    def verified_request?
      (action_name == "create" && sec_fetch_site_value == "none") || super
    end

    def ask_to_share_again
      flash[:alert] = "Sign in, then share again." unless session[:user_id]
    end
end
