module DurableAssistants
  module Telemetry
    # Rails parameter filtering does not cover unmatched requests or outbound HTTP.
    # The shared collector is pass-through, so restrict data before handing it off.
    class Exporter
      ATTRIBUTES = %w[
        http.request.method http.method http.response.status_code http.status_code
        http.route code.namespace code.function messaging.system messaging.operation
        messaging.destination.name
      ].freeze
      HTTP_METHODS = %w[GET HEAD POST PUT PATCH DELETE OPTIONS TRACE CONNECT].freeze

      def initialize(exporter)
        @exporter = exporter
      end

      def export(spans, timeout: nil)
        @exporter.export(spans.map { |span| sanitized(span) }, timeout: timeout)
      end

      def force_flush(timeout: nil)
        @exporter.force_flush(timeout: timeout)
      end

      def shutdown(timeout: nil)
        @exporter.shutdown(timeout: timeout)
      end

      private
        def sanitized(span)
          span.dup.tap do |safe|
            safe.attributes = span.attributes.to_h.slice(*ATTRIBUTES)
            if (method = safe.attributes["http.request.method"] || safe.attributes["http.method"])
              safe.name = [ HTTP_METHODS.include?(method) ? method : "HTTP", safe.attributes["http.route"] ].compact.join(" ")
            end
            # Exceptions can embed URLs and bodies. Keep causal links, not payloads.
            safe.events = []
            safe.links = span.links.to_a.map { |link| OpenTelemetry::Trace::Link.new(link.span_context) }
            safe.status = case span.status.code
            when OpenTelemetry::Trace::Status::ERROR then OpenTelemetry::Trace::Status.error
            when OpenTelemetry::Trace::Status::OK then OpenTelemetry::Trace::Status.ok
            else OpenTelemetry::Trace::Status.unset
            end
          end
        end
    end
  end
end
