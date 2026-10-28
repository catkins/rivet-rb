#!/bin/sh
set -eu

# Preview uses /pools with a flat config, not the 2.x /runner-configs API.
curl --fail-with-body --silent --show-error --retry 10 --retry-delay 2 \
  --retry-all-errors --max-time 30 \
  -X PUT "${RIVET_ENDPOINT}/pools/${RIVET_POOL_NAME}?namespace=${RIVET_NAMESPACE}" \
  -H "Authorization: Bearer ${RIVET_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{}'
