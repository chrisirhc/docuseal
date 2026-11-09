# frozen_string_literal: true

# Rerunnable measurement of the field detector against a reviewed corpus.
# See docs/field-detection/baseline-protocol.md for the manifest format.
module DetectionEvaluation
  MANIFEST_SCHEMA_VERSION = 1
  REPORT_SCHEMA_VERSION = 1

  IOU_THRESHOLDS = [0.5, 0.75].freeze

  REVIEW_STATES = %w[complete partial].freeze
  SPLITS = %w[generalization repeated].freeze
  SOURCE_KINDS = %w[digital_pdf scan image].freeze
  LOCALIZATION_CLASSES = %w[text checkbox].freeze
  POSITIVE_DISPOSITIONS = %w[used valid_unused].freeze
  DISPOSITIONS = (POSITIVE_DISPOSITIONS + %w[false_detection ignored]).freeze
  GEOMETRIES = %w[input blank].freeze

  IGNORED_OVERLAP = 0.5

  Attachment = Struct.new(:uuid, :image) do
    def image?
      image
    end
  end

  class ManifestError < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors

      super("Invalid manifest:\n#{errors.join("\n")}")
    end
  end

  module_function

  def load_manifest(path)
    manifest = JSON.parse(File.read(path))
    root = File.dirname(path)

    errors = validate_manifest(manifest, root:)

    raise ManifestError, errors if errors.any?

    manifest
  end

  def validate_manifest(manifest, root:)
    errors = []

    errors << 'unsupported schema_version' unless manifest['schema_version'] == MANIFEST_SCHEMA_VERSION

    documents = manifest['documents'].to_a

    errors << 'no documents' if documents.empty?
    errors.concat(duplicates_across_splits(documents, 'family'))
    errors.concat(duplicates_across_splits(documents, 'sha256'))

    documents.each { |document| errors.concat(validate_document(document, root:)) }

    errors
  end

  def duplicates_across_splits(documents, key)
    documents.group_by { |document| document[key] }.filter_map do |value, group|
      next if group.pluck('split').uniq.size < 2

      "#{key} #{value} appears in more than one split"
    end
  end

  def validate_document(document, root:)
    id = document['id']
    errors = []

    %w[id path sha256 family language authorization].each do |key|
      errors << "#{id}: missing #{key}" if document[key].blank?
    end

    errors << "#{id}: invalid split" unless SPLITS.include?(document['split'])
    errors << "#{id}: invalid source_kind" unless SOURCE_KINDS.include?(document['source_kind'])

    path = File.expand_path(document['path'].to_s, root)

    if !File.file?(path)
      errors << "#{id}: file not found"
    elsif Digest::SHA256.file(path).hexdigest != document['sha256']
      errors << "#{id}: sha256 does not match"
    end

    errors << "#{id}: no reviewed pages" if document['pages'].blank?

    document['pages'].to_a.each do |page|
      label = "#{id} page #{page['page']}"

      errors << "#{label}: invalid review_state" unless REVIEW_STATES.include?(page['review_state'])
      errors << "#{label}: missing reviewer" if page['reviewer'].blank?

      page['targets'].to_a.each { |target| errors.concat(validate_target(target, label)) }
    end

    errors
  end

  def validate_target(target, label)
    errors = []

    errors << "#{label}: invalid localization_class" unless LOCALIZATION_CLASSES.include?(target['localization_class'])
    errors << "#{label}: invalid disposition" unless DISPOSITIONS.include?(target['disposition'])
    errors << "#{label}: target has no input geometry" if target['input'].blank?

    GEOMETRIES.each do |geometry|
      box = target[geometry]

      errors << "#{label}: invalid #{geometry} geometry" if box && !valid_box?(box)
    end

    errors
  end

  def valid_box?(box)
    return false unless box.is_a?(Hash) && %w[x y w h].all? { |key| box[key].is_a?(Numeric) }

    box['x'] >= 0 && box['y'] >= 0 && box['w'].positive? && box['h'].positive? &&
      box['x'] + box['w'] <= 1.0001 && box['y'] + box['h'] <= 1.0001
  end

  def iou(box1, box2)
    intersection = intersection_area(box1, box2)

    return 0.0 if intersection.zero?

    intersection / ((box1['w'] * box1['h']) + (box2['w'] * box2['h']) - intersection)
  end

  def intersection_area(box1, box2)
    width = [box1['x'] + box1['w'], box2['x'] + box2['w']].min - [box1['x'], box2['x']].max
    height = [box1['y'] + box1['h'], box2['y'] + box2['h']].min - [box1['y'], box2['y']].max

    width.positive? && height.positive? ? width * height : 0.0
  end

  # Greedy, class-aware, highest confidence first. Unmatched predictions are not false positives
  # on a partial page or inside an ignored region, because neither asserts that the area is empty.
  def score_page(predictions, targets, iou_threshold:, geometry:, review_state:)
    scorable = targets.select { |target| target[geometry] }

    positives = scorable.select { |target| POSITIVE_DISPOSITIONS.include?(target['disposition']) }
    ignored = scorable.select { |target| target['disposition'] == 'ignored' }

    available = positives.dup
    matches = []
    false_positives = []

    predictions.sort_by { |prediction| -prediction['confidence'] }.each do |prediction|
      candidates = available.select { |target| target['localization_class'] == prediction['localization_class'] }
      best = candidates.max_by { |target| iou(prediction, target[geometry]) }
      best_iou = best ? iou(prediction, best[geometry]) : 0.0

      if best_iou >= iou_threshold
        available.delete_at(available.index { |target| target.equal?(best) })

        matches << { prediction:, target: best, iou: best_iou }
      elsif review_state == 'complete' && !inside_ignored?(prediction, ignored, geometry)
        false_positives << prediction
      end
    end

    { matches:, false_positives:, false_negatives: available }
  end

  def inside_ignored?(prediction, ignored, geometry)
    area = prediction['w'] * prediction['h']

    ignored.any? { |target| intersection_area(prediction, target[geometry]) / area >= IGNORED_OVERLAP }
  end

  def summarize(scores, klass: nil)
    keep = ->(item) { klass.nil? || item == klass }

    matches = scores.flat_map { |score| score[:matches] }
                    .select { |match| keep.call(match[:target]['localization_class']) }
    false_positives = scores.flat_map { |score| score[:false_positives] }
                            .count { |prediction| keep.call(prediction['localization_class']) }
    false_negatives = scores.flat_map { |score| score[:false_negatives] }
                            .count { |target| keep.call(target['localization_class']) }

    build_summary(matches, false_positives, false_negatives)
  end

  def build_summary(matches, false_positives, false_negatives)
    true_positives = matches.size
    typed = matches.select { |match| match[:target]['semantic_type'].present? }
    correct = typed.count { |match| match[:prediction]['semantic_type'] == match[:target]['semantic_type'] }

    {
      true_positives:, false_positives:, false_negatives:,
      precision: ratio(true_positives, true_positives + false_positives),
      recall: ratio(true_positives, true_positives + false_negatives),
      mean_iou: ratio(matches.sum { |match| match[:iou] }, true_positives),
      semantic_accuracy: ratio(correct, typed.size)
    }
  end

  def ratio(value, total)
    total.zero? ? nil : (value.to_f / total).round(6)
  end

  def predictions_from(provenance, stage)
    case stage
    when 'suggestion'
      provenance[:suggestions].map { |suggestion| prediction_from(suggestion) }
    when 'detector'
      floor = provenance[:parameters][:confidence]

      provenance[:detections].select { |detection| detection[:confidence] >= floor }
                             .map { |detection| prediction_from(detection) }
    end
  end

  def prediction_from(box)
    {
      'x' => box[:x], 'y' => box[:y], 'w' => box[:w], 'h' => box[:h],
      'confidence' => box[:confidence].to_f,
      'localization_class' => box[:type] == 'checkbox' ? 'checkbox' : 'text',
      'semantic_type' => box[:type]
    }
  end

  def report_for(pages)
    %w[suggestion detector].index_with do |stage|
      GEOMETRIES.index_with do |geometry|
        IOU_THRESHOLDS.to_h do |threshold|
          scores = pages.map do |page|
            score_page(page[:predictions][stage], page[:targets], iou_threshold: threshold, geometry:,
                                                                  review_state: page[:review_state])
          end

          by_class = LOCALIZATION_CLASSES.index_with { |klass| summarize(scores, klass:) }

          [threshold.to_s, { all: summarize(scores), **by_class }]
        end
      end
    end
  end

  def evaluate_document(document, root:, detector:)
    wanted = document['pages'].index_by { |page| page['page'] }
    path = File.expand_path(document['path'], root)
    attachment = Attachment.new(document['id'], document['source_kind'] == 'image')

    pages = []
    latencies = []
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    detector.call(StringIO.new(File.binread(path)), attachment) do |(_, page, _, provenance)|
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      latencies << (now - clock)
      clock = now

      reviewed = wanted[page]

      next unless reviewed

      pages << {
        document:, targets: reviewed['targets'].to_a, review_state: reviewed['review_state'],
        predictions: %w[suggestion detector].index_with { |stage| predictions_from(provenance, stage) }
      }
    end

    { pages:, latencies: }
  end

  def percentile(values, fraction)
    return nil if values.empty?

    values.sort[((values.size - 1) * fraction).round].round(4)
  end

  def peak_rss_kb
    status = '/proc/self/status'

    return File.read(status)[/VmHWM:\s+(\d+)/, 1].to_i if File.exist?(status)

    nil
  end

  def host_info
    {
      cpu_count: Etc.nprocessors,
      platform: RUBY_PLATFORM,
      ruby: RUBY_VERSION,
      os: Etc.uname.values_at(:sysname, :release, :machine).join(' ')
    }
  end

  def grouped(pages, key)
    pages.group_by { |page| page[:document][key] }.sort_by { |value, _| value.to_s }
         .to_h { |value, group| [value, report_for(group)] }
  end

  def section(pages)
    {
      page_count: pages.size,
      overall: report_for(pages),
      by_source_kind: grouped(pages, 'source_kind'),
      by_language: grouped(pages, 'language')
    }
  end

  def default_detector
    ->(io, attachment, &block) { Templates::DetectFields.call(io, attachment:, &block) }
  end

  def run(manifest_path, detector: default_detector)
    manifest = load_manifest(manifest_path)
    root = File.dirname(manifest_path)
    documents = manifest['documents'].sort_by { |document| document['id'] }

    results = documents.map { |document| evaluate_document(document, root:, detector:) }
    pages = results.flat_map { |result| result[:pages] }
    latencies = results.flat_map { |result| result[:latencies] }

    {
      report_schema_version: REPORT_SCHEMA_VERSION,
      generated_at: Time.current.iso8601,
      corpus: {
        name: manifest['name'],
        manifest_sha256: Digest::SHA256.file(manifest_path).hexdigest,
        dataset_sha256: Digest::SHA256.hexdigest(documents.pluck('sha256').sort.join("\n")),
        document_count: documents.size,
        family_count: documents.pluck('family').uniq.size,
        page_count: pages.size
      },
      model: { sha256: DetectionRuns.model_sha256, version: DetectionRuns.model_version },
      preprocessing_version: DetectionRuns::PREPROCESSING_VERSION,
      detection_schema_version: DetectionRuns::SCHEMA_VERSION,
      iou_thresholds: IOU_THRESHOLDS,
      host: host_info,
      resources: {
        page_latency_seconds: { p50: percentile(latencies, 0.5), p95: percentile(latencies, 0.95),
                                max: latencies.max&.round(4) },
        peak_rss_kb: peak_rss_kb
      },
      generalization: section(pages.select { |page| page[:document]['split'] == 'generalization' }),
      repeated_documents: section(pages.select { |page| page[:document]['split'] == 'repeated' })
    }
  end
end
