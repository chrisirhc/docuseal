# frozen_string_literal: true

RSpec.describe 'Template field detection provenance' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user, only_field_types: %w[text]) }
  let(:attachment_uuid) { template.schema.first['attachment_uuid'] }
  let(:request_uuid) { SecureRandom.uuid }

  def field(type, left, confidence)
    Templates::ImageToFields::Field.new(type:, x: left, y: 0.2, w: 0.2, h: 0.05, confidence:)
  end

  def detect(params = {})
    post "/templates/#{template.id}/detect_fields", params: { attachment_uuid:, page: 0, request_uuid: }.merge(params)
  end

  def events
    response.body.scan(/^data: (.+)$/).flatten.map { |line| JSON.parse(line) }
  end

  before do
    allow(Templates::ImageToFields).to receive_messages(resolution: 704, model_v2?: true)
    allow(Templates::ImageToFields).to receive(:call) do
      [field('text', 0.1, 0.9), field('checkbox', 0.4, 0.8), field('text', 0.7, 0.12)]
    end

    sign_in(user)
  end

  it 'persists detector output and suggestions with lineage' do
    detect

    run = DetectionRun.sole
    expect(run).to have_attributes(status: 'completed', account_id: account.id, template_id: template.id,
                                   user_id: user.id, attachment_uuid:, page: 0, source_kind: 'pdf',
                                   model_version: 'v2', schema_version: 1)
    expect(run.source_sha256).to eq(Digest::SHA256.hexdigest(template.documents.first.download))

    detectors = run.predictions.detectors.order(:position)
    suggestions = run.predictions.suggestions.order(:position)

    expect(detectors.pluck(:confidence)).to contain_exactly(be_within(1e-6).of(0.9), be_within(1e-6).of(0.8),
                                                            be_within(1e-6).of(0.12))
    expect(suggestions.pluck(:field_type)).to eq(%w[text checkbox])
    expect(suggestions.map { |s| detectors[s.detection_position].x }).to eq(suggestions.map(&:x))
    expect(run.parameters).to include('confidence' => 0.3, 'confidence_floor' => be_within(1e-6).of(0.1))
    expect(run.pages.sole).to have_attributes(page: 0, image_height: be_positive, page_width: be_positive)
  end

  it 'returns suggestion ids in the stream without changing its shape' do
    detect

    page_event, completed = events
    run = DetectionRun.sole

    expect(completed).to eq('completed' => true)
    expect(page_event).to include('attachment_uuid' => attachment_uuid, 'page' => 0, 'detection_run_uuid' => run.uuid)
    expect(page_event['fields'].first.keys).to match_array(%w[uuid type required preferences areas])
    expect(page_event['fields'].pluck('uuid')).to match_array(run.predictions.suggestions.pluck(:uuid))
  end

  it 'keeps the link to saved fields and leaves predictions intact on edits' do
    detect

    fields = events.first['fields']

    patch "/templates/#{template.id}", params: {
      template: { fields: [fields.first.merge('name' => 'Edited', 'submitter_uuid' => template.submitters.first['uuid'],
                                              'areas' => [fields.first['areas'].first.merge('x' => 0.5)])] }
    }

    expect(response).to have_http_status(:ok)

    prediction = DetectionRuns.predictions_for(template.reload).fetch(fields.first['uuid'])

    expect(prediction.x).to be_within(1e-6).of(0.1)
    expect(DetectionRun.sole.predictions.suggestions.count).to eq(2)
    expect { prediction.update!(x: 0.5) }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it 'replays duplicate delivery without running inference again' do
    detect
    first = events

    detect

    expect(events).to eq(first)
    expect(Templates::ImageToFields).to have_received(:call).once
    expect(DetectionRun.count).to eq(1)
  end

  it 'treats a new request for the same document as a rerun' do
    detect
    first_uuids = events.first['fields'].pluck('uuid')

    detect(request_uuid: SecureRandom.uuid)

    expect(DetectionRun.count).to eq(2)
    expect(DetectionRun.distinct.pluck(:source_sha256).size).to eq(1)
    expect(events.first['fields'].pluck('uuid')).not_to include(*first_uuids)
  end

  it 'keeps working for clients that send no request uuid' do
    2.times { detect(request_uuid: nil) }

    expect(DetectionRun.where(request_uuid: nil, status: 'completed').count).to eq(2)
  end

  it 'reports a request that is still running' do
    DetectionRun.create!(template:, account:, attachment_uuid:, request_uuid:, status: 'running',
                         started_at: Time.current, preprocessing_version: 1, schema_version: 1)

    detect

    expect(events).to eq([{ 'error' => DetectionRuns::ALREADY_RUNNING_ERROR }])
    expect(Templates::ImageToFields).not_to have_received(:call)
  end

  it 'retries a stale run as a new attempt' do
    stale = DetectionRun.create!(template:, account:, attachment_uuid:, request_uuid:, status: 'running',
                                 started_at: 1.hour.ago, preprocessing_version: 1, schema_version: 1)

    detect

    expect(stale.reload).to have_attributes(status: 'failed', error_class: 'StaleRun')
    expect(DetectionRun.find_by(attempt: 2)).to be_completed
  end

  it 'marks failed runs and retries them as a new attempt' do
    allow(Templates::ImageToFields).to receive(:call).and_raise(ArgumentError, 'boom')

    detect

    expect(events).to be_empty
    expect(DetectionRun.sole).to have_attributes(status: 'failed', error_class: 'ArgumentError')

    allow(Templates::ImageToFields).to receive(:call).and_return([field('text', 0.1, 0.9)])

    detect

    expect(DetectionRun.order(:attempt).pluck(:attempt, :status)).to eq([[1, 'failed'], [2, 'completed']])
  end

  it 'keeps the pages that finished before a failure' do
    allow(Templates::DetectFields).to receive(:call).and_wrap_original do |original, *args, **kwargs, &block|
      original.call(*args, **kwargs, &block)

      raise ArgumentError, 'boom'
    end

    detect

    run = DetectionRun.sole

    expect(run).to have_attributes(status: 'failed', error_class: 'ArgumentError')
    expect(run.pages.count).to eq(1)
    expect(run.predictions.suggestions.count).to eq(2)
  end

  it 'still streams fields when provenance cannot be written' do
    allow(DetectionPrediction).to receive(:insert_all!).and_raise(ActiveRecord::StatementInvalid, 'disk full')

    detect

    expect(events.first['fields'].size).to eq(2)
    expect(events.last).to eq('completed' => true)
    expect(DetectionRun.sole).to have_attributes(status: 'failed', error_class: 'ProvenanceWriteError')
  end

  it 'records one run per document for multi-document templates' do
    template = create(:template, account:, author: user, attachment_count: 2, only_field_types: %w[text])

    post "/templates/#{template.id}/detect_fields",
         params: { attachment_uuid: template.schema.pluck('attachment_uuid'), request_uuid: }

    expect(DetectionRun.pluck(:attachment_uuid)).to match_array(template.schema.pluck('attachment_uuid'))
    expect(DetectionRun.distinct.pluck(:request_uuid)).to eq([request_uuid])
    expect(DetectionRun.distinct.pluck(:page)).to eq([nil])
  end

  it 'records the model signature in use' do
    allow(Templates::ImageToFields).to receive(:model_v2?).and_return(false)

    detect

    expect(DetectionRun.sole.model_version).to eq('v1')
  end

  it 'does not expose runs across accounts' do
    other_account = create(:account)
    other_template = create(:template, account: other_account, author: create(:user, account: other_account))

    post "/templates/#{other_template.id}/detect_fields", params: { request_uuid: }

    expect(response).to have_http_status(:found)
    expect(DetectionRun.count).to eq(0)
  end

  it 'does not share an idempotency key across templates' do
    detect

    other = create(:template, account:, author: user, only_field_types: %w[text])

    post "/templates/#{other.id}/detect_fields", params: { page: 0, request_uuid: }

    expect(DetectionRun.pluck(:template_id)).to contain_exactly(template.id, other.id)
  end

  it 'removes provenance with the template' do
    detect

    expect { template.destroy! }.to change(DetectionRun, :count).to(0)
      .and change(DetectionPrediction, :count).to(0)
      .and change(DetectionRunPage, :count).to(0)
  end

  it 'records nothing when the account turns capture off' do
    AccountConfig.create!(account:, key: AccountConfig::RECORD_FIELD_DETECTIONS_KEY, value: false)

    detect

    expect(DetectionRun.count).to eq(0)
    expect(events.first.keys).to match_array(%w[attachment_uuid page fields])
    expect(events.first['fields'].size).to eq(2)
    expect(events.last).to eq('completed' => true)
  end

  it 'lets an admin turn capture off and back on' do
    post '/account_configs', params: { account_config: { key: AccountConfig::RECORD_FIELD_DETECTIONS_KEY, value: '0' } }

    expect(response).to have_http_status(:ok)
    expect(DetectionRuns.capture_enabled?(account.id)).to be(false)

    post '/account_configs', params: { account_config: { key: AccountConfig::RECORD_FIELD_DETECTIONS_KEY, value: '1' } }

    expect(DetectionRuns.capture_enabled?(account.id)).to be(true)
  end

  it 'shows the capture setting on the account page' do
    get '/settings/account'

    expect(response.body).to include(I18n.t(:record_field_detection_results))
    expect(response.body).to include(AccountConfig::RECORD_FIELD_DETECTIONS_KEY)
  end

  it 'lets an admin clear recorded detections for the account only' do
    detect
    other_account = create(:account)
    other_user = create(:user, account: other_account)
    other_template = create(:template, account: other_account, author: other_user, only_field_types: %w[text])
    DetectionRuns.recorder(template: other_template, user: other_user,
                           attachment_uuid: other_template.schema.first['attachment_uuid'],
                           request_uuid: SecureRandom.uuid, page: 0)

    get '/settings/account'
    expect(response.body).to include(I18n.t(:recorded_field_detections_count, count: 1))

    expect { delete '/settings/detection_records' }
      .to change { DetectionRun.where(account_id: account.id).count }.from(1).to(0)
      .and change(DetectionPrediction, :count).by(-5)
      .and change(DetectionRunPage, :count).by(-1)

    expect(DetectionRun.where(account_id: other_account.id).count).to eq(1)
    expect(template.reload).to be_persisted
    follow_redirect!
    expect(response.body).to include(I18n.t(:field_detection_records_cleared, count: 1))
  end

  it 'freezes a finished run' do
    detect

    expect { DetectionRun.sole.update!(status: 'failed') }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
