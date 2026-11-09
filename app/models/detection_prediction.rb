# frozen_string_literal: true

# == Schema Information
#
# Table name: detection_predictions
#
#  id                 :bigint           not null, primary key
#  confidence         :float            not null
#  detection_position :integer
#  field_type         :string           not null
#  h                  :float            not null
#  page               :integer          not null
#  position           :integer          not null
#  stage              :string           not null
#  uuid               :string
#  w                  :float            not null
#  x                  :float            not null
#  y                  :float            not null
#  created_at         :datetime         not null
#  detection_run_id   :bigint           not null
#
# Indexes
#
#  index_detection_predictions_on_position  (detection_run_id,stage,page,position) UNIQUE
#  index_detection_predictions_on_uuid      (uuid) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (detection_run_id => detection_runs.id)
#
class DetectionPrediction < ApplicationRecord
  DETECTOR_STAGE = 'detector'
  SUGGESTION_STAGE = 'suggestion'

  belongs_to :detection_run

  scope :suggestions, -> { where(stage: SUGGESTION_STAGE) }
  scope :detectors, -> { where(stage: DETECTOR_STAGE) }

  def readonly?
    persisted?
  end
end
