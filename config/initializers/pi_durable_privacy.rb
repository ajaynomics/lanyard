# Conversation content, answers, tool arguments and tokens never reach logs.
Rails.application.config.filter_parameters += %i[
  answer arguments content prompt snapshot selections text body sidecar_token rails_token
]
