# frozen_string_literal: true

RSpec.describe Templates::DetectFields do
  let(:io) { StringIO.new(Rails.root.join('spec/fixtures/sample-document.pdf').binread) }
  let(:attachment) { DetectionEvaluation::Attachment.new('attachment', false) }

  def field(type, left, confidence)
    Templates::ImageToFields::Field.new(type:, x: left, y: 0.2, w: 0.2, h: 0.05, confidence:)
  end

  before do
    allow(Templates::ImageToFields).to receive_messages(
      resolution: 704,
      call: [field('text', 0.1, 0.9), field('text', 0.5, 0.15)]
    )
  end

  it 'still returns the same three leading values to existing callers' do
    described_class.call(io, attachment:, page_number: 0) do |(attachment_uuid, page, fields)|
      expect([attachment_uuid, page]).to eq(['attachment', 0])
      expect(fields.first.keys).to eq(%i[uuid type required preferences areas])
    end
  end

  it 'snapshots detections before heuristics mutate them' do
    allow(described_class).to receive(:extract_text_fields_from_page)
      .and_return([described_class::TextFieldBox.new(x: 0.5, y: 0.2, w: 0.2, h: 0.05)])

    described_class.call(io, attachment:, page_number: 0) do |(_, _, fields, provenance)|
      expect(provenance[:detections].map { |d| d[:confidence] }).to eq([0.9, 0.15])
      expect(provenance[:suggestions].map { |s| s[:confidence] }).to eq([0.9, 1.15])
      expect(provenance[:suggestions].pluck(:uuid)).to eq(fields.pluck(:uuid))
      expect(provenance[:suggestions].pluck(:detection_position)).to eq([0, 1])
    end
  end

  it 'links distinct suggestions to identical detections' do
    allow(Templates::ImageToFields).to receive(:call).and_return([field('text', 0.1, 0.9), field('text', 0.1, 0.9)])

    described_class.call(io, attachment:, page_number: 0) do |(_, _, _, provenance)|
      expect(provenance[:suggestions].pluck(:detection_position)).to eq([0, 1])
    end
  end

  it 'records images without page geometry' do
    allow(ImageUtils).to receive(:load_vips).and_return(instance_double(Vips::Image, width: 100, height: 200))

    attachment = DetectionEvaluation::Attachment.new('a', true)

    described_class.call(StringIO.new('x'), attachment:) do |(*, provenance)|
      expect(provenance[:page]).to eq(image_width: 100, image_height: 200)
      expect(provenance[:parameters][:regexp_type]).to be(false)
    end
  end
end
