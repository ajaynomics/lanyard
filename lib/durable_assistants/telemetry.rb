module DurableAssistants
  # Instrumentation defaults can include raw URLs despite empty header lists.
  # Telemetry::Exporter is the app-side boundary for what actually leaves.
  # ActiveRecord stays out: query binds can be user text, and polls are noisy.
  module Telemetry
    INSTRUMENTATIONS = {
      "OpenTelemetry::Instrumentation::Rack" => {
        allowed_request_headers: [],
        allowed_response_headers: []
      },
      "OpenTelemetry::Instrumentation::ActionPack" => { span_naming: :semconv },
      "OpenTelemetry::Instrumentation::ActiveJob" => {},
      "OpenTelemetry::Instrumentation::Net::HTTP" => {}
    }.freeze
  end
end
