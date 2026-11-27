class Tool::CreateTurnstilePreview < Tool
  Preview = DurableAssistants::TurnstilePreview
  UNAVAILABLE = "The configured preview destination is unavailable.".freeze

  description "Ask the release owner to create a Turnstile widget for the configured preview hostname. " \
    "The secret goes only to the configured Pages preview; the answer contains only its public site key and status."
  argument :hostname, :string, min_length: 1, max_length: 150,
    description: "The exact preview hostname approved for this workspace. No URLs or wildcards."
  asks :approval, even_approving_everything: true
  reaches_others
  effect :external

  def self.available_to?(agent) = Preview::Destination.for(agent).present?
  def self.start_once? = true
  def self.exact_preview_approval? = true

  def permitted? = self.class.available_to?(agent)

  def refusal
    UNAVAILABLE unless destination&.hostname == arguments["hostname"]
  end

  def approver = agent.workspace.owner
  def previews? = true

  def approval_title(_arguments) = "Create a preview Turnstile widget?"
  def approval_note(_arguments) = "Only the configured release owner can allow this. The secret goes only to the Pages preview."

  def details(_arguments) = invocation.preview.to_h.slice("Preview hostname", "Cloudflare account", "Pages project", "Environment", "error")

  def preview
    target = destination
    if target && target.hostname == arguments["hostname"]
      { "Preview hostname" => target.hostname, "Cloudflare account" => target.account_id,
        "Pages project" => target.project, "Environment" => Preview::Destination::ENVIRONMENT, "digest" => target.digest }
    else
      { "error" => UNAVAILABLE }
    end
  end

  def call(hostname:)
    target = destination
    approval = invocation.approval
    unless target && target.hostname == hostname && invocation.preview&.fetch("digest", nil) == target.digest &&
        approval&.decision == "approve" && approval.decided_by == approver
      raise Refusal, UNAVAILABLE
    end
    Preview.new(target).create(name: "Turnstile preview #{hostname} ##{invocation.id}")
  rescue Preview::Error => error
    raise Refusal, error.message, cause: nil
  end

  private
    def destination = Preview::Destination.for(agent)
end
