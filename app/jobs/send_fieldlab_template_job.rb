# frozen_string_literal: true

# Sends a saved template to fieldlab. It is best effort: a lab that is down must never
# block or fail a save, so an error is logged and the job is not retried.
class SendFieldlabTemplateJob
  include Sidekiq::Job

  sidekiq_options queue: :webhooks, retry: false

  def perform(params = {})
    return unless Fieldlab.enabled?

    template = Template.find_by(id: params['template_id'])

    return if template.nil? || template.fields.blank?

    Fieldlab.template_saved(template)
  rescue Fieldlab::Error => e
    Rails.logger.warn("fieldlab: template #{params['template_id']} was not sent: #{e.message}")
  end
end
