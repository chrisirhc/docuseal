# frozen_string_literal: true

RSpec.describe DetectionEvaluation do
  def box(left)
    { 'x' => left, 'y' => 0.1, 'w' => 0.2, 'h' => 0.1 }
  end

  def prediction(left, klass: 'text', confidence: 0.9, type: 'text')
    box(left).merge('localization_class' => klass, 'confidence' => confidence, 'semantic_type' => type)
  end

  def target(left, klass: 'text', disposition: 'used', type: 'text')
    { 'input' => box(left), 'localization_class' => klass, 'disposition' => disposition, 'semantic_type' => type }
  end

  def score(predictions, targets, review_state: 'complete', iou_threshold: 0.5)
    described_class.score_page(predictions, targets, iou_threshold:, geometry: 'input', review_state:)
  end

  describe '.score_page' do
    it 'counts true positives, false positives, and false negatives' do
      result = score([prediction(0.1), prediction(0.7)], [target(0.1), target(0.4)])

      expect(result[:matches].size).to eq(1)
      expect(result[:false_positives].size).to eq(1)
      expect(result[:false_negatives].size).to eq(1)
    end

    it 'does not match across localization classes' do
      result = score([prediction(0.1, klass: 'checkbox')], [target(0.1)])

      expect(result[:matches]).to be_empty
    end

    it 'matches each target once, in confidence order' do
      result = score([prediction(0.1, confidence: 0.2), prediction(0.11, confidence: 0.9)], [target(0.1)])

      expect(result[:matches].sole[:prediction]['confidence']).to eq(0.9)
      expect(result[:false_positives].size).to eq(1)
    end

    it 'keeps equal targets distinct' do
      result = score([prediction(0.1)], [target(0.1), target(0.1)])

      expect(result[:false_negatives].size).to eq(1)
    end

    it 'does not count extra predictions on a partial page' do
      expect(score([prediction(0.7)], [target(0.1)], review_state: 'partial')[:false_positives]).to be_empty
    end

    it 'still counts missed listed targets on a partial page' do
      expect(score([], [target(0.1)], review_state: 'partial')[:false_negatives].size).to eq(1)
    end

    it 'does not count predictions inside an ignored region' do
      expect(score([prediction(0.1)], [target(0.1, disposition: 'ignored')])[:false_positives]).to be_empty
    end

    it 'counts a valid unused blank as a positive' do
      expect(score([prediction(0.1)], [target(0.1, disposition: 'valid_unused')])[:matches].size).to eq(1)
    end

    it 'counts a prediction on a false detection target as a false positive' do
      expect(score([prediction(0.1)], [target(0.1, disposition: 'false_detection')])[:false_positives].size).to eq(1)
    end
  end

  describe '.summarize' do
    it 'computes precision, recall, localization, and semantic accuracy' do
      scores = [score([prediction(0.1, type: 'date'), prediction(0.7)], [target(0.1, type: 'date'), target(0.4)])]

      expect(described_class.summarize(scores)).to include(precision: 0.5, recall: 0.5, mean_iou: 1.0,
                                                           semantic_accuracy: 1.0)
    end

    it 'reports unknown rather than zero when nothing was measured' do
      expect(described_class.summarize([score([], [])])).to include(precision: nil, recall: nil)
    end
  end

  describe '.run' do
    let(:dir) { Pathname(Dir.mktmpdir) }
    let(:pdf) { Rails.root.join('spec/fixtures/sample-document.pdf') }
    let(:document) do
      {
        'id' => 'doc', 'path' => 'doc.pdf', 'sha256' => Digest::SHA256.file(pdf).hexdigest, 'family' => 'a',
        'split' => 'generalization', 'source_kind' => 'digital_pdf', 'language' => 'en', 'authorization' => 'ref',
        'pages' => [{ 'page' => 0, 'review_state' => 'complete', 'reviewer' => 'r', 'targets' => [target(0.1)] }]
      }
    end
    let(:detector) do
      lambda do |_io, attachment, &block|
        block.call([attachment.uuid, 0, [], {
                     detections: [{ type: 'text', confidence: 0.9, **box(0.1).symbolize_keys },
                                  { type: 'text', confidence: 0.05, **box(0.7).symbolize_keys }],
                     suggestions: [{ type: 'text', confidence: 1.9, **box(0.1).symbolize_keys }],
                     parameters: { confidence: 0.3 }
                   }])
      end
    end

    before do
      FileUtils.cp(pdf, dir.join('doc.pdf'))
      allow(DetectionRuns).to receive(:model_version).and_return('v2')
    end

    after { FileUtils.remove_entry(dir) }

    def write_manifest(documents)
      dir.join('manifest.json').tap do |path|
        path.write({ schema_version: 1, name: 'test', documents: }.to_json)
      end
    end

    it 'keeps repeated documents apart from generalization results' do
      dir.join('doc2.pdf').binwrite("#{pdf.binread}\n")

      repeated = document.merge('id' => 'doc2', 'path' => 'doc2.pdf', 'family' => 'b', 'split' => 'repeated',
                                'sha256' => Digest::SHA256.file(dir.join('doc2.pdf')).hexdigest)

      report = described_class.run(write_manifest([document, repeated]).to_s, detector:)

      expect(report[:generalization][:page_count]).to eq(1)
      expect(report[:repeated_documents][:page_count]).to eq(1)
      expect(report[:corpus]).to include(document_count: 2, family_count: 2)
    end

    it 'applies the operating threshold to detector output' do
      report = described_class.run(write_manifest([document]).to_s, detector:)

      summary = report[:generalization][:overall]['detector']['input']['0.5'][:all]

      expect(summary).to include(true_positives: 1, false_positives: 0)
    end

    it 'rejects a family that straddles splits' do
      other = document.merge('id' => 'doc2', 'split' => 'repeated')

      expect { described_class.run(write_manifest([document, other]).to_s, detector:) }
        .to raise_error(described_class::ManifestError, /family a appears in more than one split/)
    end

    it 'rejects a changed source file' do
      expect { described_class.run(write_manifest([document.merge('sha256' => 'x')]).to_s, detector:) }
        .to raise_error(described_class::ManifestError, /sha256 does not match/)
    end

    it 'rejects unreviewed or unauthorized examples' do
      unreviewed = document.merge('authorization' => nil, 'pages' => [{ 'page' => 0, 'review_state' => 'unreviewed' }])

      expect { described_class.run(write_manifest([unreviewed]).to_s, detector:) }
        .to raise_error(described_class::ManifestError) { |error|
          expect(error.errors).to include('doc: missing authorization', 'doc page 0: invalid review_state',
                                          'doc page 0: missing reviewer')
        }
    end
  end
end
