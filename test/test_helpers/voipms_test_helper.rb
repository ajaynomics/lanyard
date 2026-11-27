# The install's voip.ms settings for a test, and voip.ms itself as WebMock
# stubs: each request's form is kept, and nothing reaches voip.ms.
module VoipmsTestHelper
  def install_voipms_settings
    settings = Rails.application.config.x.voipms
    @previous_voipms = settings.dup
    settings.merge!(username: "texts@example.com", password: "synthetic-api-password")
  end

  def remove_voipms_settings
    Rails.application.config.x.voipms.replace(@previous_voipms) if @previous_voipms
  end

  # The forms voip.ms was sent; a block can answer each form differently.
  def stub_voipms(answer = { status: "success", sms: 23434 })
    forms = []
    stub_request(:any, /voip\.ms/).to_return do |request|
      form = voipms_form(request)
      forms << form
      { body: (block_given? ? yield(form) : answer).to_json, headers: { "Content-Type" => "application/json" } }
    end
    forms
  end

  # voip.ms as it was in a live case: it takes each text, then sends no answer
  # before the app stops waiting, as if it hung past the timeout. What it took
  # it lists, as getSMS or getMMS would, from `listed_after` on: its list may
  # lag. The texts it took, each with its id.
  def voipms_taking_then_hanging(listed_after: 0.seconds, first_id: 10863123)
    taken = []
    stub_request(:post, /voip\.ms/).to_return do |request|
      form = voipms_form(request)
      kind = form["method"].delete_prefix("send").delete_prefix("get").downcase
      if form["method"].start_with?("send")
        taken << { "id" => (first_id + taken.size).to_s, "kind" => kind, "date" => Time.current.utc.strftime("%Y-%m-%d %H:%M:%S"),
                   "type" => "0", "did" => form["did"], "contact" => form["dst"], "message" => form["message"], "listed_at" => Time.current + listed_after }
        raise Net::ReadTimeout
      end
      listed = taken.select { it["kind"] == kind && it["did"] == form["did"] && it["contact"] == form["contact"] && !it["listed_at"].after?(Time.current) }
      answer = listed.any? ? { status: "success", kind => listed.map { it.except("kind", "listed_at") } } : { status: "no_#{kind}" }
      { body: answer.to_json, headers: { "Content-Type" => "application/json" } }
    end
    taken
  end

  # The fields of a request, read as voip.ms reads them: multipart/form-data only.
  def voipms_form(request)
    type = request.headers["Content-Type"].to_s
    return {} unless type.start_with?("multipart/form-data")
    env = Rack::MockRequest.env_for("/", method: "POST", input: request.body.to_s, "CONTENT_TYPE" => type)
    Rack::Request.new(env).POST
  end
end
