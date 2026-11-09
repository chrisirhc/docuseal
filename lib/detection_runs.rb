# frozen_string_literal: true

module DetectionRuns
  SCHEMA_VERSION = 1

  # Bump when rendering, trimming, padding, or heuristics change detection results.
  PREPROCESSING_VERSION = 1

  STALE_AFTER = 15.minutes

  ALREADY_RUNNING_ERROR = 'Field detection is already running for this request.'

  UUID_REGEXP = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  # Provenance is best effort: a recording failure is reported and detection carries on.
  class Recorder
    attr_reader :run, :replay_run

    def initialize(template:, attachment_uuid:, user:, request_uuid:, page:)
      @template = template
      @attachment_uuid = attachment_uuid
      @user = user
      @request_uuid = request_uuid.to_s.match?(UUID_REGEXP) ? request_uuid.to_s : nil
      @page = page
    end

    def start
      safely { begin_run if DetectionRuns.capture_enabled?(@template.account_id) }

      self
    end

    def in_progress?
      @in_progress == true
    end

    def run_uuid
      run&.uuid
    end

    def track
      yield

      finish(failure: @broken ? 'ProvenanceWriteError' : nil)
    rescue StandardError => e
      finish(failure: e.class.name)

      raise
    end

    def record_source(bytes, kind:)
      safely do
        run&.update!(source_kind: kind, source_sha256: Digest::SHA256.hexdigest(bytes),
                     source_byte_size: bytes.bytesize)
      end
    end

    def record_page(page, provenance)
      safely do
        next unless run

        DetectionRun.transaction do
          if run.parameters.blank?
            run.update!(parameters: provenance[:parameters], model_version: DetectionRuns.model_version)
          end

          run.pages.create!(page:, **provenance[:page])

          rows = prediction_rows(page, provenance)

          DetectionPrediction.insert_all!(rows) if rows.any?
        end
      end
    end

    private

    def begin_run
      return create_run(attempt: 1) if @request_uuid.nil?

      latest = @template.detection_runs.where(request_uuid: @request_uuid, attachment_uuid: @attachment_uuid)
                        .order(attempt: :desc).first

      if latest&.completed?
        @replay_run = latest
      elsif latest&.running? && latest.started_at > STALE_AFTER.ago
        @in_progress = true
      else
        expire(latest)

        create_run(attempt: latest ? latest.attempt + 1 : 1)
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def expire(run)
      return unless run&.running?

      run.update!(status: 'failed', error_class: 'StaleRun', finished_at: Time.current)
    end

    def create_run(attempt:)
      DetectionRun.transaction(requires_new: true) do
        @run = @template.detection_runs.create!(
          account_id: @template.account_id, user_id: @user&.id, attachment_uuid: @attachment_uuid,
          request_uuid: @request_uuid, attempt:, page: @page, status: 'running', started_at: Time.current,
          model_sha256: DetectionRuns.model_sha256, preprocessing_version: PREPROCESSING_VERSION,
          schema_version: SCHEMA_VERSION
        )
      end
    end

    def finish(failure: nil)
      safely do
        run&.update!(status: failure ? 'failed' : 'completed', error_class: failure, finished_at: Time.current)
      end
    end

    def prediction_rows(page, provenance)
      now = Time.current
      common = { detection_run_id: run.id, page:, created_at: now }

      detections = provenance[:detections].each_with_index.map do |detection, position|
        common.merge(stage: DetectionPrediction::DETECTOR_STAGE, position:, uuid: nil, detection_position: nil,
                     **geometry(detection))
      end

      suggestions = provenance[:suggestions].each_with_index.map do |suggestion, position|
        common.merge(stage: DetectionPrediction::SUGGESTION_STAGE, position:, uuid: suggestion[:uuid],
                     detection_position: suggestion[:detection_position], **geometry(suggestion))
      end

      detections + suggestions
    end

    def geometry(box)
      { field_type: box[:type], x: box[:x], y: box[:y], w: box[:w], h: box[:h], confidence: box[:confidence] }
    end

    def safely
      yield
    rescue StandardError => e
      @broken = true

      Rollbar.error(e) if defined?(Rollbar)
      Rails.logger.error("Detection provenance failed: #{e.class}: #{e.message}")

      nil
    end
  end

  module_function

  def recorder(**)
    Recorder.new(**).start
  end

  def capture_enabled?(account_id)
    AccountConfig.find_by(account_id:, key: AccountConfig::RECORD_FIELD_DETECTIONS_KEY)&.value != false
  end

  # Deletes every recorded run of an account, with its pages and predictions.
  # Returns the number of runs removed.
  def clear(account_id)
    DetectionRun.where(account_id:).in_batches(of: 500).sum do |runs|
      ids = runs.ids

      DetectionRun.transaction do
        DetectionPrediction.where(detection_run_id: ids).delete_all
        DetectionRunPage.where(detection_run_id: ids).delete_all
        DetectionRun.where(id: ids).delete_all
      end
    end
  end

  # Rebuilds the streamed page events of a completed run, with the original field UUIDs.
  def page_events(run)
    suggestions = run.predictions.suggestions.order(:page, :position).group_by(&:page)

    run.pages.order(:page).map do |page|
      fields = suggestions.fetch(page.page, []).map { |prediction| field_from(prediction, run) }

      [run.attachment_uuid, page.page, fields]
    end
  end

  def field_from(prediction, run)
    {
      uuid: prediction.uuid,
      type: prediction.field_type,
      required: prediction.field_type == 'signature',
      preferences: {},
      areas: [{
        x: prediction.x, y: prediction.y, w: prediction.w, h: prediction.h,
        page: prediction.page, attachment_uuid: run.attachment_uuid
      }]
    }
  end

  # The suggestion behind each saved field, keyed by field UUID.
  def predictions_for(template)
    uuids = template.fields.pluck('uuid')

    DetectionPrediction.suggestions.where(uuid: uuids)
                       .joins(:detection_run).where(detection_runs: { template_id: template.id })
                       .index_by(&:uuid)
  end

  def model_sha256
    return @model_sha256 if defined?(@model_sha256)

    @model_sha256 = File.exist?(Templates::ImageToFields::MODEL_PATH) ? file_sha256 : nil
  end

  def file_sha256
    Digest::SHA256.file(Templates::ImageToFields::MODEL_PATH).hexdigest
  end

  def model_version
    Templates::ImageToFields.model_v2? ? 'v2' : 'v1'
  end
end
