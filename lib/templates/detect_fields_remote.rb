# frozen_string_literal: true

module Templates
  # "Detect fields" answered by fieldlab instead of the built-in model. It yields what
  # Templates::DetectFields yields, one page at a time, so the stream and the provenance
  # records keep their shape.
  module DetectFieldsRemote
    # Raised when fieldlab fails before any page was produced, so the caller can still
    # fall back to the built-in detector without sending a page twice.
    Unavailable = Class.new(StandardError)

    module_function

    def call(data, template:, attachment:, page_number: nil)
      pages = page_number ? [page_number] : (0...page_count(data, attachment)).to_a
      fields = []

      pages.each_with_index do |page, index|
        reply = fetch(data, template:, attachment:, page:, first: index.zero?)
        page_fields = reply['fields'].map { |field| build_field(field, attachment.uuid) }

        yield [attachment.uuid, page, page_fields, provenance(reply, page_fields)] if block_given?

        fields.concat(page_fields)
      end

      fields
    end

    def fetch(data, template:, attachment:, page:, first:)
      Fieldlab.detect(data, template:, attachment_uuid: attachment.uuid, page:)
    rescue Fieldlab::Error => e
      raise unless first

      raise Unavailable, e.message
    end

    def page_count(data, attachment)
      return 1 if attachment.image?

      doc = Pdfium::Document.open_bytes(data)

      doc.page_count
    ensure
      doc&.close
    end

    def build_field(field, attachment_uuid)
      area = field['areas'].first

      {
        uuid: SecureRandom.uuid,
        type: field['type'],
        required: field['type'] == 'signature',
        preferences: {},
        areas: [{ x: area['x'], y: area['y'], w: area['w'], h: area['h'], page: area['page'], attachment_uuid: }],
        confidence: field['confidence'],
        detector_type: field['detector_type'] || field['type']
      }
    end

    # The detector row is fieldlab's box with the class its detector gave it, and the
    # suggestion is the same box with its final type. Both transient keys are removed from
    # the fields, which then match the built-in detector's.
    def provenance(reply, page_fields)
      rows = page_fields.map do |field|
        area = field[:areas].first

        { type: field.delete(:detector_type), x: area[:x], y: area[:y], w: area[:w], h: area[:h],
          confidence: field.delete(:confidence) }
      end

      suggestions = page_fields.each_with_index.map do |field, position|
        rows[position].merge(uuid: field[:uuid], detection_position: position, type: field[:type])
      end

      page = reply['pages'].first || {}

      {
        detections: rows,
        suggestions:,
        page: { image_width: page['image_width'], image_height: page['image_height'],
                page_width: page['width'], page_height: page['height'], rotation: page['rotation'] },
        parameters: { detector: 'fieldlab', method: reply['method'], confidence: Fieldlab::MIN_CONFIDENCE },
        model: { version: reply.dig('detector', 'name'), sha256: reply.dig('detector', 'sha256') }
      }
    end
  end
end
