class Connectors::GoogleAccountStartsController < ApplicationController
  layout "outside"
  skip_before_action :track_ahoy_visit
  rate_limit to: 10, within: 1.minute

  def create
    no_store
    response.set_header("Referrer-Policy", "no-referrer")
    connector = find_in_workspace(:connectors, params[:connector_id])
    @agent_bound = params.key?(:agent_id)
    token = GoogleAccountStart.issue!(connector, by: Current.user, issued_email: Current.email, expected_email: params[:expected_email],
      agent_id: (params[:agent_id].to_s if @agent_bound))
    @link = URI.join(GoogleAccountStart.canonical_origin, google_account_start_path).tap { |url| url.fragment = token }.to_s
    status = request.request_parameters["delivery"] == "text" ? text_link(connector) : :created
    render :create, status: status
  rescue GoogleAccountStart::InvalidAddress
    render plain: "Enter the expected Google email address.", status: :unprocessable_content
  end

  private
    def text_link(connector)
      workspace = connector.workspace
      agent = connector.conversation.agent
      membership = workspace.memberships.find_by(user: Current.user)
      from = agent.phone_number
      to = membership&.phone_number
      account = agent.voipms_account
      unless account && Agent::PHONE_NUMBER.match?(from) && Agent::PHONE_NUMBER.match?(to) && !workspace.barred_member(agent, [ to ])
        @text_status = "Texting is not available for this link. You can copy it below."
        return :unprocessable_content
      end

      if DurableAssistants::Voipms.send_text(from:, to:, body: @link, account:).present?
        @text_status = "Text sent to your number on file."
        :created
      else
        text_unconfirmed
      end
    rescue DurableAssistants::Voipms::Error, DurableAssistants::Voipms::Unconfirmed
      text_unconfirmed
    end

    def text_unconfirmed
      @text_status = "We couldn't confirm the text was sent. Check your phone before trying again."
      :service_unavailable
    end
end
