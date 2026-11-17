# The development image follows the CI job and the production Dockerfile: Ruby on Alpine,
# with the system libraries the gems bind to at run time.
FROM ruby:4.0.9-alpine

RUN apk add --no-cache \
      bash build-base chromium curl font-carlito font-liberation git gzip leptonica libpq-dev \
      nodejs onnxruntime openssh-client postgresql-client redis tar tzdata unzip vips wget yaml-dev yarn zstd

# The same pinned PDFium build as the production image.
RUN wget -q -O /tmp/pdfium.zip "https://github.com/docusealco/pdfium-binaries/releases/download/20260920/pdfium-musl-$(uname -m).zip" && \
    case "$(uname -m)" in \
      x86_64)  echo "bbca8a648dbd1ba81f9c6c223f21dc394cf1ad381c6c17d60c6dcc4a7d3a2ae0  /tmp/pdfium.zip" ;; \
      aarch64) echo "73b72ed79b9bfdd494dee7e863482c24971a8d4b11f6cd1289aa170d31304a1f  /tmp/pdfium.zip" ;; \
    esac | sha256sum -c - && \
    unzip -q /tmp/pdfium.zip -d /tmp/pdfium && cp /tmp/pdfium/lib/libpdfium.so /usr/lib/libpdfium.so && rm -rf /tmp/pdfium /tmp/pdfium.zip

# Legacy OpenSSL providers, as in production: some PDFs are signed with old algorithms.
RUN printf '.include = /etc/ssl/openssl.cnf\n\n[provider_sect]\ndefault = default_sect\nlegacy = legacy_sect\n\n[default_sect]\nactivate = 1\n\n[legacy_sect]\nactivate = 1\n' > /etc/openssl_legacy.cnf

ENV OPENSSL_CONF=/etc/openssl_legacy.cnf \
    BUNDLE_PATH=/usr/local/bundle \
    VIPS_BLOCK_UNTRUSTED=1 \
    EDITOR=vi

WORKDIR /workspace
