# frozen_string_literal: true

namespace :detection do
  desc 'Measure field detection against a reviewed corpus. Usage: rake detection:baseline MANIFEST=a.json OUTPUT=b.json'
  task baseline: :environment do
    manifest = ENV.fetch('MANIFEST')
    output = ENV.fetch('OUTPUT')

    report = DetectionEvaluation.run(manifest)

    File.write(output, JSON.pretty_generate(report))

    puts "Wrote #{output}"
  end
end
