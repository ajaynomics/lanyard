class GoogleAccountStartsController < ApplicationController
  allow_unauthenticated_access only: %i[ show create callback ]
  # Visit analytics keep the full landing URL, including the provider query.
  skip_before_action :track_ahoy_visit
  layout "outside"

  prepend_before_action :protect_page
  rate_limit to: 30, within: 1.minute, name: "show", only: :show
  rate_limit to: 10, within: 1.minute, name: "start", only: :create, unless: :preview?
  rate_limit to: 10, within: 1.minute, name: "preview", only: :create, if: :preview?
  rate_limit to: 5, within: 1.minute, name: "preview-token", only: :create, if: :preview?, by: :preview_digest
  rate_limit to: 30, within: 1.minute, name: "callback", only: :callback

  # A no-referrer form sends Origin null. The POST also requires the
  # browser's same-origin Fetch Metadata, more narrowly than Rails' default.
  self.forgery_protection_origin_check = false

  def show
    head :bad_request if request.query_string.present?
  end

  def create
    return head :forbidden unless request.headers["Sec-Fetch-Site"] == "same-origin" &&
      request.origin.in?([ nil, "null", GoogleAccountStart.canonical_origin ])
    return head :bad_request if request.query_string.present? || request.media_type != "application/x-www-form-urlencoded"
    fields = request.request_parameters
    allowed = %w[ authenticity_token start_token ]
    allowed << "preview" if preview?
    return head :bad_request unless (fields.keys - allowed).empty?
    return preview if preview?

    browser = cookies[browser_cookie]
    browser = SecureRandom.urlsafe_base64(32) unless GoogleAccountStart.browser_nonce?(browser)
    url = GoogleAccountStart.start(fields["start_token"], browser: browser)
    return failed(:gone) unless url

    cookies[browser_cookie] = { value: browser, httponly: true, secure: request.ssl?, same_site: :lax,
      path: "/", expires: GoogleAccountStart::LASTS.from_now }
    # The provider URL includes state. Don't emit Rails' redirect log for it.
    head :see_other, location: url
  end

  def callback
    return head :method_not_allowed if request.head?

    query = request.query_parameters
    state = query["state"]
    attempt = GoogleAccountStart.claim_callback(state, browser: cookies[browser_cookie])
    connector = attempt&.current_connector
    return failed(:gone) unless connector
    return failed(:unprocessable_content) unless valid_response?(query)

    grant = attempt.grant_for(connector)
    tokens = grant.exchange(code: query["code"], verifier: GoogleAccountStart.verifier(state))
    return failed(:unprocessable_content) unless identity_matches?(attempt, connector, grant, tokens)
    return failed(:gone) unless attempt.save_grant(tokens)
    @agent_name = connector.conversation.agent.name if connector.gmail_grant?
    render :complete
  rescue DurableAssistants::Google::Error
    failed(:unprocessable_content)
  end

  private
    def browser_cookie = request.ssl? ? "__Host-google_account_start" : "google_account_start"

    def preview?
      request.media_type == "application/x-www-form-urlencoded" && request.request_parameters["preview"] == "1"
    end

    def preview_digest
      @preview_digest ||= GoogleAccountStart.preview_digest(request.request_parameters["start_token"])
    end

    def preview
      connector = GoogleAccountStart.preview_connector(preview_digest)
      return head :gone unless connector
      return head :no_content unless connector.gmail_grant?

      render plain: connector.conversation.agent.name
    end

    def identity_matches?(attempt, connector, grant, tokens)
      if connector.google.in?(%i[ calendar drive ])
        DurableAssistants::Google::AccountIdentity.verify!(access_token: tokens.fetch("access_token"), &attempt.method(:matches?))
      else
        attempt.matches?(grant.address(tokens))
      end
    end

    def valid_response?(query)
      !query.key?("error") && query["code"].is_a?(String) && query["code"].match?(/\A[!-~]{1,4096}\z/) &&
        (!query.key?("iss") || query["iss"] == DurableAssistants::Google::AccountGrant::ISSUER)
    end

    def protect_page
      no_store
      response.set_header("Referrer-Policy", "no-referrer")
      preview_source = "connect-src 'self'; " if action_name == "show"
      response.set_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; #{preview_source}style-src 'self' 'unsafe-inline'; img-src 'self'; form-action 'self' https://accounts.google.com; base-uri 'none'; frame-ancestors 'none'")
      head :not_found unless canonical_request?
      head :not_acceptable unless performed? || request.format.html? || (action_name == "create" && request.format.text? && preview?)
    end

    def canonical_request?
      origin = GoogleAccountStart.canonical_origin
      return false unless origin && request.base_url == origin
      address = URI(origin)
      request.get_header("HTTP_HOST").to_s.downcase.in?([ address.authority, "#{address.host}:#{address.port}" ])
    end

    def failed(status) = render(:failed, status: status)
end
