# Development container

Ruby 4.0.9 on Alpine with PDFium, ONNX Runtime, libvips and Chromium, as in CI and the
production image, plus Postgres 18.

## With VS Code or another devcontainer client

Open the repository and choose "Reopen in Container". `setup.sh` installs the gems and
node modules, downloads the detection model and prepares the databases.

## With Docker alone

```sh
docker compose -f .devcontainer/docker-compose.yml up -d --build
docker compose -f .devcontainer/docker-compose.yml exec app .devcontainer/setup.sh
docker compose -f .devcontainer/docker-compose.yml exec app bash
```

## Inside the container

```sh
bin/rails s -b 0.0.0.0        # http://127.0.0.1:13020 on the host
bin/shakapacker-dev-server    # optional: rebuilds JavaScript as you edit
bundle exec rspec
bundle exec rubocop
```

Gems, node modules and the database live in Docker volumes, so the host checkout holds no
Linux binaries. Remove them with `docker compose -f .devcontainer/docker-compose.yml down -v`.

`FIELDLAB_URL` points at a fieldlab server on the host's port 8765
(see `docs/field-detection/fieldlab.md`). Start the containers with `FIELDLAB_URL=` to
use the built-in detector only.
