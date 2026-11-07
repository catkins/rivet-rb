#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
logs="$PWD/tmp/ci-logs"
mkdir -p "$logs"

docker=(docker)
if ! docker info >/dev/null 2>&1; then
  docker=(sudo docker)
fi
"${docker[@]}" info >/dev/null
compose=("${docker[@]}" compose -p "rivet-ci-${BUILDKITE_JOB_ID:-$$}" -f compose.yaml -f docker/compose.host.yaml)
runner_pid=""
cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$runner_pid" ]]; then
    kill "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" || true
  fi
  "${compose[@]}" logs --no-color > "$logs/services.log" 2>&1 || true
  "${compose[@]}" down --volumes --remove-orphans || true
  exit "$status"
}
trap cleanup EXIT

echo "--- Install locked dependencies"
bundler_version="$(awk '/^BUNDLED WITH$/{getline; print $1}' Gemfile.lock)"
gem install bundler --version "$bundler_version" --no-document
bundle config set --local path vendor/bundle
bundle check || bundle install
npm ci --prefix test/interop --no-audit --no-fund

echo "--- Build and lint before starting services"
bundle exec rake compile
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings

echo "--- Check YARD documentation"
bundle exec yard doc --fail-on-warning
bundle exec yard stats --list-undoc --fail-on-warning | tee "$logs/yard.log"
grep -Eq '^[[:space:]]*100\.00% documented' "$logs/yard.log"

echo "--- Start isolated Rivet and Silo services"
"${compose[@]}" config --quiet
"${compose[@]}" up -d --wait engine
"${compose[@]}" run --rm --no-deps engine-init
export RIVET_ENDPOINT=http://127.0.0.1:6420
export RIVET_TOKEN=dev
export RIVET_NAMESPACE=default
export RIVET_POOL_NAME=default
export RIVETKIT_ENGINE_SPAWN=never
export AWS_ACCESS_KEY_ID=rivetdev
export AWS_SECRET_ACCESS_KEY=rivetdev-local-password
export AWS_REGION=us-east-1
export S3_ENDPOINT=http://127.0.0.1:9000
export S3_BUCKET=rivet-local
curl --fail --silent --show-error "$RIVET_ENDPOINT/health"
bundle exec ruby examples/server.rb > "$logs/runner.log" 2>&1 &
runner_pid=$!

echo "--- Full Ruby suite, including unattended crash recovery and S3"
bundle exec rake test 2>&1 | tee "$logs/tests.log"
grep -Eq ', 0 skips$' "$logs/tests.log"

echo "--- Executable counter client and TypeScript interoperability"
bundle exec ruby examples/client.rb
npm test --prefix test/interop
