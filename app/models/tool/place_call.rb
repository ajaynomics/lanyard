# Rings any number the install's voice agent names (docs/phone.md), through
# the voice gateway's call trigger. The install's owner chose no per-call
# approval and no list of numbers: the number is checked only as data, an
# international number's digits, which go to the gateway and nothing else.
# None is ever made twice: a call that may have rung is "uncertain", never
# tried again. It runs in the job role (effect :external, InvocationCallJob),
# never inline in a request.
class Tool::PlaceCall < Tool
  # E.164: an optional +, then 7 to 15 digits, the country code first (never 0).
  NUMBER = /\A\+?([1-9][0-9]{6,14})\z/
  # The gateway accepts one URL-safe token; anything else is no token.
  TOKEN = /\A[A-Za-z0-9_-]{1,256}\z/
  NO_TOKEN = "The call trigger's token file is missing, empty or unreadable, so no call was made."
  NEVER_AGAIN = "Not tried again."
  UNCERTAIN = "The phone may have rung, so whether the call reached anyone is unknown. #{NEVER_AGAIN}"
  # What the gateway's status means (its trigger's own contract, docs/phone.md).
  OUTCOMES = {
    202 => [ "carrier_answered", "The carrier answered the call. That alone doesn't show the person heard you, " \
      "or that sound went both ways. #{NEVER_AGAIN}" ],
    409 => [ "uncertain", "The gateway didn't connect the call: the line was busy, calls were closed, " \
      "or it rang and nobody answered. #{UNCERTAIN}" ],
    401 => [ "failed", "The gateway refused this install's token, so nothing was dialled. #{NEVER_AGAIN}" ],
    503 => [ "failed", "The gateway couldn't reach its phone system before dialling, so nothing was dialled. #{NEVER_AGAIN}" ],
    504 => [ "uncertain", "The gateway lost its phone system after asking it to dial. #{UNCERTAIN}" ]
  }.freeze
  # The trigger's codes, from its own table (the gateway's trigger.py, its status table): 400,
  # 404, 405 and 413 refuse the request before any phone-system call; 503 is a
  # failure before the dial was asked for (connect, banner or login); 504 one
  # after. Any status not named here is uncertain.
  REFUSED_BEFORE_DIALLING = [ 400, 404, 405, 413 ].freeze

  description "Phone a number. The gateway rings it and connects you at once; " \
    "a call is never tried again, whatever its result."
  argument :number, :string, pattern: "^\\+?[1-9][0-9]{6,14}$",
    description: "The number in international form, country code first, 7 to 15 digits, no spaces, as +442071838750 or 15555550123."
  # A call reaches someone else, so the normal policy asks first; an install or
  # workspace that approves everything doesn't.
  asks :approval
  reaches_others
  effect :external

  # Only the agent the install binds to voice, with the trigger and its
  # token's file set.
  def self.available_to?(agent)
    voice = DurableAssistants.config(:voice)
    voice&.enabled == true && voice.agent_id.to_s == agent.id.to_s &&
      voice.values_at(:call_trigger_url, :call_trigger_token_file).all?(&:present?)
  end

  # A job run again after its worker died mid-call would ring again.
  def self.start_once? = true

  def permitted? = self.class.available_to?(agent)

  def recipients = [ arguments["number"] ]

  # Checked where the request lands (web), which has no bearer: so only the
  # number here. The job, which holds the token, checks it in #call.
  def refusal
    "#{arguments["number"].to_s.inspect} is not a phone number in international form." unless digits
  end

  def call(number:)
    raise Refusal, refusal if refusal
    raise Refusal, NO_TOKEN unless bearer
    number = digits
    status = DurableAssistants::CallTrigger.ring(DurableAssistants.config(:voice, :call_trigger_url), bearer, number)
    outcome, note = OUTCOMES.fetch(status) do
      if status.in?(REFUSED_BEFORE_DIALLING)
        [ "failed", "The gateway turned the request away (HTTP #{status}) before dialling, so nothing was dialled. #{NEVER_AGAIN}" ]
      else
        [ "uncertain", "The gateway answered HTTP #{status} after the request was sent. #{UNCERTAIN}" ]
      end
    end
    { call: outcome, number: number, note: note }
  rescue DurableAssistants::CallTrigger::NotSent => error
    { call: "failed", number: number, note: "Couldn't reach the gateway (#{error.message}), so nothing was dialled. #{NEVER_AGAIN}" }
  rescue DurableAssistants::CallTrigger::Unknown => error
    { call: "uncertain", number: number, note: "The request was sent, then cut off or timed out (#{error.message}). #{UNCERTAIN}" }
  end

  private
    def digits = NUMBER.match(arguments["number"].to_s)&.[](1)

    # Read at each call, so a rotated token needs no restart; never logged,
    # nor named in an error or a result.
    def bearer
      token = File.read(DurableAssistants.config(:voice, :call_trigger_token_file).to_s, 1_024)&.chomp
      token if TOKEN.match?(token.to_s)
    rescue SystemCallError, IOError
      nil
    end
end
