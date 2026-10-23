#!/bin/bash
# Builds the side-by-side development app. It has its own bundle identifier,
# preferences and screenshot folder, so the official Tendedero.app keeps
# running untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

export APP_NAME="${APP_NAME:-Tendedero Dev}"
export BUNDLE_ID="${BUNDLE_ID:-app.tendedero.Tendedero.dev}"
export APP_PATH="${APP_PATH:-build/Tendedero Dev.app}"
export VERSION="${VERSION:-1.6.0-dev.1}"
export BUNDLE_VERSION="${BUNDLE_VERSION:-1}"

exec scripts/build-app.sh "$@"
