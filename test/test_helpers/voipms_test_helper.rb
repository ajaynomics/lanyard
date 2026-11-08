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

  # voip.ms answering every request with `answer`; the forms it was sent.
  def stub_voipms(answer = { status: "success", sms: 23434 })
    forms = []
    stub_request(:any, /voip\.ms/).to_return do |request|
      forms << voipms_form(request)
      { body: answer.to_json, headers: { "Content-Type" => "application/json" } }
    end
    forms
  end

  def voipms_form(request)
    URI.decode_www_form(request.body.to_s).to_h
  end
end
