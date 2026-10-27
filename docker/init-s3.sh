#!/bin/sh
set -eu

mc alias set local "${S3_ENDPOINT}" "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}"
mc mb --ignore-existing "local/${S3_BUCKET}"
mc stat "local/${S3_BUCKET}"
