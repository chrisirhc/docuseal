# frozen_string_literal: true

RSpec.describe 'Template field detection through fieldlab' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user, only_field_types: %w[text]) }
  let(:attachment_uuid) { template.schema.first['attachment_uuid'] }

  let(:reply) do
    {
      'method' => 'hybrid',
      'detector' => { 'name' => 'fieldlab/hybrid', 'sha256' => 'a' * 64 },
      'pages' => [{ 'page' => 0, 'width' => 612.0, 'height' => 792.0, 'rotation' => 0,
                    'image_width' => 1236, 'image_height' => 1600 }],
      'fields' => [
        { 'type' => 'signature', 'detector_type' => 'text', 'confidence' => 0.91,
          'areas' => [{ 'x' => 0.1, 'y' => 0.2, 'w' => 0.3, 'h' => 0.05, 'page' => 0 }] },
        { 'type' => 'checkbox', 'detector_type' => 'checkbox', 'confidence' => 0.8,
          'areas' => [{ 'x' => 0.5, 'y' => 0.4, 'w' => 0.02, 'h' => 0.02, 'page' => 0 }] }
      ]
    }
  end

  def detect
    post "/templates/#{template.id}/detect_fields", params: { attachment_uuid:, page: 0 }
  end

  def events
    response.body.scan(/^data: (.+)$/).flatten.map { |line| JSON.parse(line) }
  end

  before do
    allow(Fieldlab).to receive_messages(enabled?: true, detect: reply)
    allow(Templates::ImageToFields).to receive_messages(resolution: 704, model_v2?: true)
    allow(Templates::ImageToFields).to receive(:call).and_return([])

    sign_in(user)
  end

  it 'streams fieldlab fields in the built-in shape and records where they came from' do
    detect

    page_event, completed = events
    run = DetectionRun.sole

    expect(completed).to eq('completed' => true)
    expect(page_event['fields'].pluck('type')).to eq(%w[signature checkbox])
    expect(page_event['fields'].first.keys).to match_array(%w[uuid type required preferences areas])
    expect(page_event['fields'].first['areas'].first).to include('attachment_uuid' => attachment_uuid, 'page' => 0)
    expect(Fieldlab).to have_received(:detect).with(anything, template:, attachment_uuid:, page: 0)
    expect(Templates::ImageToFields).not_to have_received(:call)

    expect(run).to have_attributes(status: 'completed', model_version: 'fieldlab/hybrid', model_sha256: 'a' * 64)
    expect(run.parameters).to include('detector' => 'fieldlab', 'method' => 'hybrid')
    expect(run.pages.sole).to have_attributes(image_width: 1236, page_height: 792.0)
    expect(run.predictions.detectors.order(:position).pluck(:field_type)).to eq(%w[text checkbox])
    expect(run.predictions.suggestions.order(:position).pluck(:field_type)).to eq(%w[signature checkbox])
    expect(run.predictions.suggestions.pluck(:uuid)).to match_array(page_event['fields'].pluck('uuid'))
  end

  it 'falls back to the built-in detector when fieldlab cannot be reached' do
    allow(Fieldlab).to receive(:detect).and_raise(Fieldlab::Error, 'connection refused')

    detect

    expect(events.last).to eq('completed' => true)
    expect(Templates::ImageToFields).to have_received(:call)
    expect(DetectionRun.sole).to have_attributes(status: 'completed', model_version: 'v2')
  end

  it 'sends a saved template to fieldlab, and its file when fieldlab asks for it' do
    requests = []

    allow(Fieldlab).to receive(:post) do |path, **options|
      requests << [path, options[:params]]

      path == '/api/docuseal/events' && requests.size == 1 ? { 'missing' => [attachment_uuid] } : { 'missing' => [] }
    end

    patch "/templates/#{template.id}", params: { template: { name: 'Renamed' } }

    expect(SendFieldlabTemplateJob.jobs.size).to eq(1)

    SendFieldlabTemplateJob.drain

    expect(requests.map(&:first)).to eq(%w[/api/docuseal/events /api/docuseal/documents /api/docuseal/events])
    expect(requests[1].last).to include(template_id: template.id, attachment_uuid:)
  end

  it 'sends nothing when fieldlab is not configured' do
    allow(Fieldlab).to receive(:enabled?).and_return(false)

    patch "/templates/#{template.id}", params: { template: { name: 'Renamed' } }
    detect

    expect(SendFieldlabTemplateJob.jobs).to be_empty
    expect(Templates::ImageToFields).to have_received(:call)
  end
end
