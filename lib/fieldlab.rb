# frozen_string_literal: true

# Client for fieldlab, the field detection lab that runs beside this app.
#
# It is optional. Without FIELDLAB_URL nothing here runs: "Detect fields" uses the built-in
# detector and no template leaves the app. With it:
#
#   * "Detect fields" asks fieldlab for the fields of each page (Templates::DetectFieldsRemote).
#   * Every saved template is sent to fieldlab, where its fields become labels for the
#     document and score the detection that preceded them (SendFieldlabTemplateJob).
#
# fieldlab may send page images on to a hosted model. See docs/field-detection/fieldlab.md
# before turning it on for documents that must stay on this instance.
module Fieldlab
  Error = Class.new(StandardError)

  DETECT_TIMEOUT = 300
  EVENT_TIMEOUT = 30
  MIN_CONFIDENCE = 0.3

  module_function

  def url
    ENV['FIELDLAB_URL'].presence
  end

  def enabled?
    url.present?
  end

  # Names this app in fieldlab, so two instances can both have a template 1.
  def instance
    ENV['FIELDLAB_INSTANCE'].presence || Docuseal::HOST
  end

  # Fields of one page. Returns fieldlab's reply: 'fields', 'pages', 'method', 'detector'.
  def detect(data, template:, attachment_uuid:, page:)
    params = { page:, template_id: template.id, attachment_uuid:, instance:, min_confidence: MIN_CONFIDENCE }

    post('/api/detect', params:, body: data, content_type: 'application/octet-stream', timeout: DETECT_TIMEOUT)
  end

  # Sends the template as saved. fieldlab names the documents it does not hold yet. Those
  # are uploaded, and the template is sent once more.
  def template_saved(template)
    payload = { instance:, template: template_payload(template) }

    reply = post('/api/docuseal/events', body: payload.to_json, content_type: 'application/json')
    missing = Array.wrap(reply['missing'])

    return reply if missing.empty?

    template.documents.preload(:blob).select { |document| missing.include?(document.uuid) }.each do |document|
      post('/api/docuseal/documents', params: { instance:, template_id: template.id, attachment_uuid: document.uuid },
                                      body: document_data(document), content_type: 'application/octet-stream')
    end

    post('/api/docuseal/events', body: payload.to_json, content_type: 'application/json')
  end

  # The built-in detector answered "Detect fields". Its fields go to fieldlab as the run
  # `docuseal-builtin`, so a later save scores it beside fieldlab's own runs.
  def detected(payload)
    post('/api/docuseal/detected', body: payload.merge('instance' => instance).to_json,
                                   content_type: 'application/json')
  end

  def enqueue_detected(template:, attachment_uuid:, pages:, fields:, seconds:, reason:)
    return unless enabled? && DetectionRuns.capture_enabled?(template.account_id)

    payload = { template_id: template.id, attachment_uuid:, pages:, fields:, seconds:, reason: }

    SendFieldlabDetectedJob.perform_async('payload' => payload.as_json)
  end

  def enqueue_template_saved(template)
    return unless enabled? && DetectionRuns.capture_enabled?(template.account_id)

    # The builder saves after every change. A short delay lets the last save of a burst win.
    SendFieldlabTemplateJob.perform_in(5.seconds, 'template_id' => template.id)
  end

  # What "Detect fields" sends: the stored preview for an image, the file itself for a PDF.
  def document_data(document)
    if document.image?
      document.preview_images.joins(:blob).find_by(blob: { filename: ['0.png', '0.jpg'] }).download
    else
      document.download
    end
  end

  def template_payload(template)
    {
      id: template.id,
      name: template.name,
      fields: template.fields,
      schema: template.schema.map { |item| item.slice('attachment_uuid', 'name') }
    }
  end

  def post(path, body:, content_type:, params: {}, timeout: EVENT_TIMEOUT)
    response = connection(timeout).post(path) do |request|
      request.params.update(params.compact)
      request.headers['Content-Type'] = content_type
      request.body = body
    end

    raise Error, "fieldlab answered #{response.status}" unless response.success?

    reply = JSON.parse(response.body)

    raise Error, reply['error'] if reply.is_a?(Hash) && reply['error'].present?

    reply
  rescue Faraday::Error, JSON::ParserError => e
    raise Error, "#{e.class}: #{e.message}"
  end

  def connection(timeout)
    Faraday.new(url:, request: { timeout:, open_timeout: 5 })
  end
end
