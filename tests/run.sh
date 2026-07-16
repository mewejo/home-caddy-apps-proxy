#!/usr/bin/env bash
# Local TDD loop: build the image, then run the test suite against it.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-home-caddy-apps-proxy:test}"
docker build -t "$IMAGE" .
IMAGE="$IMAGE" tests/test.sh
