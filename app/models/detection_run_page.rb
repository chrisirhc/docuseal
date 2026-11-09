# frozen_string_literal: true

# == Schema Information
#
# Table name: detection_run_pages
#
#  id               :bigint           not null, primary key
#  image_height     :integer
#  image_width      :integer
#  page             :integer          not null
#  page_height      :float
#  page_width       :float
#  rotation         :integer
#  created_at       :datetime         not null
#  detection_run_id :bigint           not null
#
# Indexes
#
#  index_detection_run_pages_on_detection_run_id_and_page  (detection_run_id,page) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (detection_run_id => detection_runs.id)
#
class DetectionRunPage < ApplicationRecord
  belongs_to :detection_run

  def readonly?
    persisted?
  end
end
