#!/bin/sh
set -eu

# Same normal runner pool setup as upstream v2.3.30 self-host Compose.
curl --fail-with-body --silent --show-error --retry 10 --retry-delay 2 \
  --retry-all-errors --max-time 30 \
  -X PUT "${RIVET_ENDPOINT}/runner-configs/${RIVET_POOL_NAME}?namespace=${RIVET_NAMESPACE}" \
  -H "Authorization: Bearer ${RIVET_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"datacenters":{"default":{"normal":{}}}}'
