# Conversation content, answers, tool arguments and tokens never reach logs:
# the sidecar's frames (tail, thinking, a tool's output), an agent's
# instructions and purpose, a skill's markdown, and a pasted pi connector
# file (json), whose headers and env carry secrets.
Rails.application.config.filter_parameters += %i[
  answer arguments content prompt snapshot selections text body sidecar_token rails_token
  tail thinking output instructions purpose markdown json
]
