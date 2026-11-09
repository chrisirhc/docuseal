# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize
class CreateDetectionRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :detection_runs do |t|
      t.string :uuid, null: false, index: { unique: true }
      t.references :account, null: false, foreign_key: true, index: true
      t.references :template, null: false, foreign_key: true, index: false
      t.bigint :user_id
      t.string :attachment_uuid, null: false
      t.string :request_uuid
      t.integer :attempt, null: false, default: 1
      t.integer :page
      t.string :status, null: false
      t.string :source_kind
      t.string :source_sha256
      t.bigint :source_byte_size
      t.string :model_sha256
      t.string :model_version
      t.integer :preprocessing_version, null: false
      t.integer :schema_version, null: false
      t.text :parameters, null: false
      t.string :error_class
      t.datetime :started_at, null: false
      t.datetime :finished_at

      t.timestamps

      t.index %i[template_id request_uuid attachment_uuid attempt], unique: true,
                                                                    name: 'index_detection_runs_on_request'
      t.index %i[account_id source_sha256]
    end

    create_table :detection_run_pages do |t|
      t.references :detection_run, null: false, foreign_key: true, index: false
      t.integer :page, null: false
      t.integer :image_width
      t.integer :image_height
      t.float :page_width
      t.float :page_height
      t.integer :rotation
      t.datetime :created_at, null: false

      t.index %i[detection_run_id page], unique: true
    end

    create_table :detection_predictions do |t|
      t.references :detection_run, null: false, foreign_key: true, index: false
      t.string :uuid
      t.string :stage, null: false
      t.integer :page, null: false
      t.integer :position, null: false
      t.integer :detection_position
      t.string :field_type, null: false
      t.float :x, null: false
      t.float :y, null: false
      t.float :w, null: false
      t.float :h, null: false
      t.float :confidence, null: false
      t.datetime :created_at, null: false

      t.index %i[detection_run_id stage page position], unique: true,
                                                        name: 'index_detection_predictions_on_position'
      t.index :uuid, unique: true
    end
  end
end
# rubocop:enable Metrics/AbcSize
