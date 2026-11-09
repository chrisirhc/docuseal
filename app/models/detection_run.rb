# frozen_string_literal: true

# == Schema Information
#
# Table name: detection_runs
#
#  id                    :bigint           not null, primary key
#  attachment_uuid       :string           not null
#  attempt               :integer          default(1), not null
#  error_class           :string
#  finished_at           :datetime
#  model_sha256          :string
#  model_version         :string
#  page                  :integer
#  parameters            :text             not null
#  preprocessing_version :integer          not null
#  request_uuid          :string
#  schema_version        :integer          not null
#  source_byte_size      :bigint
#  source_kind           :string
#  source_sha256         :string
#  started_at            :datetime         not null
#  status                :string           not null
#  uuid                  :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :bigint           not null
#  template_id           :bigint           not null
#  user_id               :bigint
#
# Indexes
#
#  index_detection_runs_on_account_id                    (account_id)
#  index_detection_runs_on_account_id_and_source_sha256  (account_id,source_sha256)
#  index_detection_runs_on_request                       (template_id,request_uuid,attachment_uuid,attempt) UNIQUE
#  index_detection_runs_on_uuid                          (uuid) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (template_id => templates.id)
#
class DetectionRun < ApplicationRecord
  STATUSES = %w[running completed failed].freeze

  belongs_to :account
  belongs_to :template

  has_many :pages, class_name: 'DetectionRunPage', dependent: :delete_all, inverse_of: :detection_run
  has_many :predictions, class_name: 'DetectionPrediction', dependent: :delete_all, inverse_of: :detection_run

  attribute :parameters, :string, default: -> { {} }
  attribute :uuid, :string, default: -> { SecureRandom.uuid }

  serialize :parameters, coder: JSON

  validates :status, inclusion: { in: STATUSES }

  before_update :ensure_running

  STATUSES.each do |status|
    define_method(:"#{status}?") { self.status == status }
  end

  private

  def ensure_running
    raise ActiveRecord::ReadOnlyRecord, 'Finished detection run is immutable' unless status_was == 'running'
  end
end
