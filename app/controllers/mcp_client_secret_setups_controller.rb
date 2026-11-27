class McpClientSecretSetupsController < ApplicationController
  allow_unauthenticated_access
  layout "outside"
  rate_limit to: 30, within: 1.minute, name: "show", only: :show
  rate_limit to: 10, within: 1.minute, name: "redeem", only: :create
  before_action :protect_form

  # Like SignInLink: a no-referrer page sends Origin null. Rails still
  # checks Sec-Fetch-Site before accepting the submit.
  self.forgery_protection_origin_check = false

  def show
    head :bad_request if request.query_string.present?
  end

  def create
    return head :bad_request if request.query_string.present? || request.media_type != "application/x-www-form-urlencoded"
    fields = request.request_parameters
    return head :bad_request unless fields.keys.all? { |key| %w[ authenticity_token setup_token client_secret ].include?(key) }
    setup = McpClientSecretSetup.find_by_token(fields["setup_token"]) # tenancy-ok: the token only authorizes one setup
    return head :gone unless setup&.fill!(secret: fields["client_secret"])
    render :saved
  end

  private
    def protect_form
      no_store
      response.set_header("Referrer-Policy", "no-referrer")
      response.set_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
    end
end
