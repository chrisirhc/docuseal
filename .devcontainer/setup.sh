#!/bin/sh
# Prepares a fresh container. Safe to run again after a Gemfile or yarn.lock change.
set -eu

cd "$(dirname "$0")/.."

bundle check >/dev/null 2>&1 || bundle install --jobs 4 --retry 3

# The onnxruntime gem ships a glibc library. On Alpine it must point at the system one.
vendored=$(bundle exec ruby -e "print Dir[Gem::Specification.find_by_name('onnxruntime').gem_dir + '/vendor/*.so'].first")
[ -n "$vendored" ] && ln -sf /usr/lib/libonnxruntime.so.1 "$vendored"

yarn install --frozen-lockfile --network-timeout 1000000

# The field detection model, as the production image downloads it.
[ -f tmp/model.onnx ] || wget -q -O tmp/model.onnx \
  "https://github.com/docusealco/fields-detection/releases/download/2.0.0/model_704_int8.onnx"

bin/rails db:prepare
RAILS_ENV=test bin/rails db:prepare

echo "Ready. Start the app with: bin/rails s -b 0.0.0.0   (http://127.0.0.1:13020 on the host)"
echo "Run the specs with:        bundle exec rspec"
