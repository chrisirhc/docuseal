# frozen_string_literal: true

class TemplatesDetectFieldsController < ApplicationController
  include ActionController::Live

  load_and_authorize_resource :template

  def create
    response.headers['Content-Type'] = 'text/event-stream'

    sse = SSE.new(response.stream)

    documents =
      if params[:attachment_uuid].present?
        @template.documents.where(uuid: params[:attachment_uuid])
      else
        @template.schema_documents
      end

    documents = documents.preload(:blob)

    page_number = params[:page].presence&.to_i

    documents.each do |document|
      recorder = DetectionRuns.recorder(template: @template, attachment_uuid: document.uuid, user: current_user,
                                        request_uuid: params[:request_uuid], page: page_number)

      if recorder.in_progress?
        return sse.write({ error: DetectionRuns::ALREADY_RUNNING_ERROR })
      elsif recorder.replay_run
        replay_run(sse, recorder.replay_run)

        next
      end

      recorder.track { detect_document(sse, document, recorder, page_number) }
    end

    sse.write({ completed: true })
  ensure
    response.stream.close
  end

  private

  def detect_document(sse, document, recorder, page_number)
    data = Fieldlab.document_data(document)

    recorder.record_source(data, kind: document.image? ? 'image' : 'pdf')

    emit = lambda do |(attachment_uuid, page, fields, provenance)|
      recorder.record_page(page, provenance)

      sse.write({ attachment_uuid:, page:, fields:, detection_run_uuid: recorder.run_uuid }.compact)
    end

    unless Fieldlab.enabled?
      return Templates::DetectFields.call(StringIO.new(data), attachment: document, page_number:, &emit)
    end

    reason = detect_with_fieldlab(data, document, page_number, sse, &emit)

    detect_builtin_and_report(data, document, page_number, reason, &emit) unless reason.nil?
  end

  # nil when fieldlab answered. Otherwise why the built-in detector must answer: fieldlab
  # could not be reached, or it was set on its own page to let this app's detector answer.
  def detect_with_fieldlab(data, document, page_number, sse, &)
    waiting = ->(page, seconds) { sse.write({ waiting: 'fieldlab', page:, seconds: }) }

    Templates::DetectFieldsRemote.call(data, template: @template, attachment: document, page_number:, waiting:, &)

    Rails.logger.info("fieldlab: Detect fields on template #{@template.id} answered by fieldlab")

    nil
  rescue Templates::DetectFieldsRemote::Unavailable => e
    Rails.logger.warn("fieldlab: Detect fields on template #{@template.id} uses the built-in detector: #{e.message}")

    e.message
  end

  # Runs the built-in detector and sends its fields to fieldlab in the background, so the
  # lab holds both detectors' answers on the same documents.
  def detect_builtin_and_report(data, document, page_number, reason)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pages = []
    fields = []

    Templates::DetectFields.call(StringIO.new(data), attachment: document, page_number:) do |event|
      pages << event[1]
      fields.concat(event[2])

      yield event
    end

    seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)

    Fieldlab.enqueue_detected(template: @template, attachment_uuid: document.uuid, pages:, fields:, seconds:, reason:)
  end

  def replay_run(sse, run)
    DetectionRuns.page_events(run).each do |attachment_uuid, page, fields|
      sse.write({ attachment_uuid:, page:, fields:, detection_run_uuid: run.uuid })
    end
  end
end
