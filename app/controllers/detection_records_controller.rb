# frozen_string_literal: true

class DetectionRecordsController < ApplicationController
  def destroy
    authorize!(:manage, AccountConfig.new(account: current_account, key: AccountConfig::RECORD_FIELD_DETECTIONS_KEY))

    count = DetectionRuns.clear(current_account.id)

    redirect_back(fallback_location: settings_account_path,
                  notice: I18n.t('field_detection_records_cleared', count:))
  end
end
