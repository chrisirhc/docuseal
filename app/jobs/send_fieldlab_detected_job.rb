# frozen_string_literal: true

# Sends the built-in detector's answer to fieldlab. Best effort, like
# SendFieldlabTemplateJob: an error is logged and the job is not retried.
class SendFieldlabDetectedJob
  include Sidekiq::Job

  sidekiq_options queue: :webhooks, retry: false

  def perform(params = {})
    return unless Fieldlab.enabled?

    Fieldlab.detected(params['payload'])
  rescue Fieldlab::Error => e
    template_id = params.dig('payload', 'template_id')

    Rails.logger.warn("fieldlab: built-in detection of template #{template_id} was not sent: #{e.message}")
  end
end
