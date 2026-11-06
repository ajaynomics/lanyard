require "test_helper"
require "open3"

class TelemetryPrivacyTest < ActiveSupport::TestCase
  [ "", "old", "http/dup" ].each do |convention|
    test "real request and outbound HTTP spans exclude sensitive URLs with #{convention.presence || 'default'} conventions" do
      result = telemetry_probe(<<~'RUBY', convention: convention)
        require "rack/mock"
        client = Rack::MockRequest.new(Rails.application)
        [ "/up", "/missing/PRIVATE_PATH" ].each do |path|
          client.get("#{path}?token=PRIVATE_TOKEN&email=PRIVATE_EMAIL@example.com", "HTTP_HOST" => "www.example.com")
        end
        WebMock.stub_request(:post, "https://upstream.invalid/PRIVATE_PATH?token=PRIVATE_TOKEN").to_return(status: 200, body: "PRIVATE_BODY")
        Net::HTTP.start("upstream.invalid", 443, use_ssl: true) do |http|
          http.post("/PRIVATE_PATH?token=PRIVATE_TOKEN", "PRIVATE_BODY")
        end
        OpenTelemetry.tracer_provider.force_flush
        spans = captured.finished_spans
        puts "TELEMETRY_RESULT=" + JSON.generate(
          kinds: spans.map(&:kind), data: spans.map(&:to_h).inspect,
          responses: spans.map do |span|
            attributes = span.attributes.to_h
            [ span.kind, attributes["http.request.method"] || attributes["http.method"],
              attributes["http.response.status_code"] || attributes["http.status_code"] ]
          end,
          attributes: spans.map { |span| span.attributes.to_h }
        )
      RUBY

      assert_includes result.fetch("kinds"), "server", "#{convention}: must exercise real Rack spans"
      assert_includes result.fetch("responses"), [ "client", "POST", 200 ], "#{convention}: must capture the stubbed POST, not just the guard GET"
      %w[PRIVATE_TOKEN PRIVATE_EMAIL PRIVATE_PATH PRIVATE_BODY].each do |value|
        assert_not_includes result.fetch("data"), value, convention
      end
      attributes = result.fetch("attributes")
      assert_empty attributes.flat_map(&:keys) & %w[url.query url.path url.full http.target http.url]
      assert attributes.any? { |item| item["http.route"] == "/up" }, "keep matched route patterns"
      assert attributes.any? { |item| (item["http.response.status_code"] || item["http.status_code"]) == 404 }
    end
  end

  test "export removes request-bearing names and payloads without losing trace context" do
    result = telemetry_probe(<<~'RUBY')
      tracer = OpenTelemetry.tracer_provider.tracer("privacy-test")
      linked = tracer.start_span("linked operation")
      link = OpenTelemetry::Trace::Link.new(linked.context, { "payload" => "PRIVATE_TOKEN" })
      linked.finish
      span = tracer.start_span("GET /items/PRIVATE_TOKEN", links: [ link ], attributes: {
        "http.request.method" => "GET", "http.response.status_code" => 500,
        "http.route" => "/items/:id", "url.path" => "/items/PRIVATE_TOKEN",
        "unknown.capture.field" => "PRIVATE_TOKEN"
      })
      span.add_event("PRIVATE_TOKEN", attributes: { "payload" => "PRIVATE_TOKEN" })
      span.record_exception(ArgumentError.new("PRIVATE_TOKEN"))
      span.status = OpenTelemetry::Trace::Status.error("PRIVATE_TOKEN")
      span.finish
      OpenTelemetry.tracer_provider.force_flush
      exported = captured.finished_spans.find { |item| item.span_id == span.context.span_id }
      puts "TELEMETRY_RESULT=" + JSON.generate(
        data: exported.to_h.inspect, name: exported.name, attributes: exported.attributes,
        status: exported.status.code, events: exported.events,
        linked: exported.links.to_a.any? { |item| item.span_context == linked.context },
        link_attributes: exported.links.to_a.map(&:attributes),
        original: span.attributes["unknown.capture.field"],
        resource: exported.resource.attribute_enumerator.to_h
      )
    RUBY

    assert_not_includes result.fetch("data"), "PRIVATE_TOKEN"
    assert_equal "GET /items/:id", result.fetch("name")
    assert_equal 500, result.fetch("attributes").fetch("http.response.status_code")
    assert_equal 2, result.fetch("status"), "preserve the error code, not its description"
    assert_empty result.fetch("events")
    assert result.fetch("linked"), "Active Job links must survive without their payloads"
    assert result.fetch("link_attributes").all?(&:blank?)
    assert_equal "PRIVATE_TOKEN", result.fetch("original"), "do not mutate another processor's span"
    assert_equal "test", result.fetch("resource").fetch("deployment.environment")
  end

  test "without an endpoint the SDK stays inactive and requests still work" do
    result = telemetry_probe(<<~'RUBY', endpoint: nil)
      require "rack/mock"
      response = Rack::MockRequest.new(Rails.application).get("/up", "HTTP_HOST" => "www.example.com")
      puts "TELEMETRY_RESULT=" + JSON.generate(
        configured: OpenTelemetry.tracer_provider.is_a?(OpenTelemetry::SDK::Trace::TracerProvider),
        spans: captured.finished_spans.length, status: response.status
      )
    RUBY

    assert_not result.fetch("configured")
    assert_equal 0, result.fetch("spans")
    assert_equal 200, result.fetch("status")
  end

  private
    def telemetry_probe(script, convention: "", endpoint: "https://collector.invalid")
      boot = <<~'RUBY'
        require "json"
        require "webmock"
        WebMock.enable!
        WebMock.disable_net_connect!
        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"
        captured = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
        OpenTelemetry::Exporter::OTLP::Exporter.define_singleton_method(:new) { |**| captured }
        require_relative "config/environment"
        # Standalone probes must enable the adapter, not just configure WebMock.
        begin
          Net::HTTP.get(URI("https://unstubbed.invalid/"))
          abort "network guard did not reject an unstubbed request"
        rescue WebMock::NetConnectNotAllowedError
        end
      RUBY
      output, error, status = Open3.capture3(
        { "RAILS_ENV" => "test", "OTEL_EXPORTER_OTLP_ENDPOINT" => endpoint, "OTEL_SEMCONV_STABILITY_OPT_IN" => convention },
        RbConfig.ruby, "-e", boot + script + "\nOpenTelemetry.tracer_provider.shutdown if OpenTelemetry.tracer_provider.respond_to?(:shutdown)\n", chdir: Rails.root
      )
      assert status.success?, "#{error}\n#{output}"
      JSON.parse(output.lines.find { |line| line.start_with?("TELEMETRY_RESULT=") }.delete_prefix("TELEMETRY_RESULT="))
    end
end
