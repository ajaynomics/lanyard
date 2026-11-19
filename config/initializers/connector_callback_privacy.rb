# Own the final response, including one Rails builds after the action raises.
Rails.application.config.middleware.insert_before 0, DurableAssistants::ConnectorCallbackPrivacy
