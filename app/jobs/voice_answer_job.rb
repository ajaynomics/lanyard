# Off the webhook, which OpenAI wants answered within seconds. Never retried:
# an accept that may have reached OpenAI is not sent again. An accepted call
# is then listened to until it ends, holding one of the voice queue's threads
# (config/queue.yml), so a call waits behind no sweep and delays none.
class VoiceAnswerJob < ApplicationJob
  queue_as :voice

  def perform(voice_call)
    config = DurableAssistants.config(:voice)
    return unless config&.enabled == true && config.api_key.present?

    voice_call.answer(config)
    voice_call.listen(config)
  rescue DurableAssistants::Live::Error => error
    Rails.logger.warn("Voice call #{voice_call.id} not answered: #{error.message}")
  end
end
