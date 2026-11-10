module DurableAssistants
  # What an error report may contain. Request bodies and job arguments are not among them, and
  # stack frames do not keep locals: a body is not filtered by key name, so
  # whatever a user typed would otherwise ride along with the exception.
  module Glitchtip
    module_function

    def apply(sentry)
      # send_default_pii= rebuilds data_collection from the legacy flag.
      # Set the locals flag first so that rebuild does not turn them back on,
      # then force bodies off either way.
      sentry.include_local_variables = false
      sentry.send_default_pii = false
      sentry.data_collection.http_bodies = []
      sentry.data_collection.stack_frame_variables = false
      # A job's arguments (a notice's words, a room's message) stay out of a report.
      sentry.data_collection.queues = false
      sentry.before_send = ->(event, hint) { scrub(event, hint) }
    end

    def scrub(event, _hint)
      request = event.request
      if request
        request.data = nil
        request.cookies = nil
        request.query_string = nil
        request.env = nil
      end
      event
    end
  end
end
