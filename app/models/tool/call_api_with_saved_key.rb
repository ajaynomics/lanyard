# An HTTPS call to an API with a key from the vault (docs/passwords.md), for
# a service with an API rather than a page to sign in on. Picked one by one: a
# key acts in someone's account, so an agent has this only once a person
# switches it on. The first call with each key asks, under every policy; the
# person may then answer "Always" for that key. The request is
# DurableAssistants::KeyedRequest; the model reads only the status and body.
class Tool::CallApiWithSavedKey < Tool
  description "Call an API over https with a key saved in the password manager. Name the saved entry (see " \
    "list_saved_sign_ins, or ask the person): the call goes only to that entry's own host, with its key as a bearer " \
    "token, and you never see the key. You get back the status and the response body."
  argument :name, :string, min_length: 1, max_length: 200, description: "The saved entry's name."
  argument :method, :string, enum: DurableAssistants::KeyedRequest::METHODS, description: "The HTTP method."
  argument :path, :string, min_length: 1, max_length: 2_000, description: "The path on the entry's host, starting with /: /v2/bookings."
  argument :query, :object, required: false, additional_properties: { type: "string" },
    description: "Query parameters, each a string: {\"status\": \"upcoming\"}."
  argument :body, :object, required: false, description: "A JSON body, sent as application/json."
  argument :headers, :object, required: false, additional_properties: { type: "string" },
    description: "Extra headers the API needs, such as {\"cal-api-version\": \"2024-08-13\"}. Not Authorization."
  asks :approval, even_approving_everything: true
  always_with_recipients
  reaches_others
  effect :external

  def self.available? = DurableAssistants::Passbolt.url.present?

  # "Always" is per saved key, never for every key.
  def recipients = [ arguments["name"].to_s ]
  def contacts = []

  def permitted? = DurableAssistants::Passbolt.configured?(agent)

  # A password its own mail or calendar account uses never goes out as a key,
  # to its server's API or any other (Agent#reserved_sign_in?).
  def refusal = (Tool::SignInWithSavedPassword::RESERVED.sub("filled in a browser", "used as a key") if agent.reserved_sign_in?(arguments["name"]))

  def call(name:, method:, path:, query: nil, body: nil, headers: nil)
    raise Refusal, refusal if refusal
    entry = DurableAssistants::Passbolt.sign_in_by_name(agent, name)
    DurableAssistants::KeyedRequest.new(entry, method:, path:, query:, body:, headers:).perform
  rescue DurableAssistants::Passbolt::Error, DurableAssistants::KeyedRequest::Error => error
    raise Refusal, error.message
  end
end
