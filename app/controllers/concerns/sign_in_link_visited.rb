# A one-time link for someone outside to fill one empty saved sign-in
# (SignInLink), opened without a sign-in. Open to the internet, so rate
# limited by each controller (docs/open-routes.md); the token is the whole
# claim. Its pages keep no copy (no-store), send no referrer, and run no
# script, ours or anyone's (layouts/outside).
module SignInLinkVisited
  extend ActiveSupport::Concern

  included do
    allow_unauthenticated_access
    layout "outside"
    before_action do
      no_store
      response.set_header("Referrer-Policy", "no-referrer")
    end
    before_action :set_link
  end

  private
    def set_link
      @token = params[:sign_in_link_token] || params[:token]
      @link = SignInLink.find_by_token(@token) or raise ActiveRecord::RecordNotFound # tenancy-ok: the token is the visitor's whole claim, to one link
    end

    def refused(why = @link.why_refused)
      @why = why
      render "sign_in_links/refused", status: :gone
    end
end
